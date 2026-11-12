import { env } from "cloudflare:workers";

// VibeLog's test log service.
//
//   POST /upload   from the app, with an invite code: a batch of small text files
//   GET  /list     for the owner: upload keys, newest pages first
//   GET  /get      for the owner: one upload
//   POST /delete   for the owner: one upload, once pulled
//
// No IP address, header or time of day is stored with an upload, only what the app sent, which it
// has already made anonymous. Uploads are deleted after 90 days, or sooner once the owner pulls
// them with --delete.

const MAX_BODY = 4 * 1024 * 1024;
// Each upload is deleted this long after it arrives, pulled or not, so nothing is kept for long.
const KEEP_SECONDS = 90 * 24 * 60 * 60;
// An upload unpacked: logs compress about tenfold, so this is what 4 MB packed can hold.
const MAX_UNPACKED = 24 * 1024 * 1024;
const MAX_FILE = 2 * 1024 * 1024;
const MAX_FILES = 200;
const MODEL = /^iPhone\d{1,2},\d{1,2}$/;
const VERSION = /^\d{1,3}(\.\d{1,3}){1,3}$/;
const INSTALL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const FILE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/;
const TEXT_KINDS = /\.(log|json|csv|txt|gcsv)$/;

type Upload = {
	install: string;
	model: string;
	ios: string;
	app: string;
	files: { name: string; text: string }[];
};

function reply(status: number, body: unknown = {}): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json", "cache-control": "no-store" },
	});
}

function bearer(request: Request): string {
	const header = request.headers.get("authorization") ?? "";
	return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

/** Compares without leaking how much of a guess was right. */
function same(a: string, b: string): boolean {
	const x = new TextEncoder().encode(a);
	const y = new TextEncoder().encode(b);
	let diff = x.length ^ y.length;
	for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
	return diff === 0;
}

function invited(code: string): boolean {
	if (code.length < 6) return false;
	return (env.INVITE_CODES ?? "")
		.split(",")
		.map((c) => c.trim())
		.filter((c) => c.length >= 6)
		.some((c) => same(c, code));
}

function isOwner(request: Request): boolean {
	const token = env.ADMIN_TOKEN ?? "";
	return token.length >= 24 && same(bearer(request), token);
}

/** What makes an upload acceptable, or why it isn't. */
export function check(upload: Upload): string | null {
	if (!upload || typeof upload !== "object") return "not an upload";
	if (!INSTALL.test(upload.install ?? "")) return "bad install";
	if (!MODEL.test(upload.model ?? "")) return "bad model";
	if (!VERSION.test(upload.ios ?? "")) return "bad iOS version";
	if (!VERSION.test(upload.app ?? "")) return "bad app version";
	if (!Array.isArray(upload.files) || upload.files.length === 0 || upload.files.length > MAX_FILES) return "bad files";
	for (const file of upload.files) {
		if (!FILE_NAME.test(file?.name ?? "") || !TEXT_KINDS.test(file.name)) return `bad name ${String(file?.name).slice(0, 40)}`;
		if (typeof file.text !== "string" || file.text.length > MAX_FILE) return `bad text in ${file.name}`;
	}
	return null;
}

/** Unpacks raw DEFLATE, stopping once it passes the limit, so a small bomb can't fill memory. */
async function inflate(packed: ArrayBuffer): Promise<string | null> {
	const stream = new Blob([packed]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
	const reader = stream.getReader();
	const parts: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		total += value.length;
		if (total > MAX_UNPACKED) {
			await reader.cancel();
			return null;
		}
		parts.push(value);
	}
	const joined = new Uint8Array(total);
	let at = 0;
	for (const part of parts) {
		joined.set(part, at);
		at += part.length;
	}
	return new TextDecoder().decode(joined);
}

async function upload(request: Request): Promise<Response> {
	if (!invited(bearer(request))) return reply(401, { error: "invite code refused" });
	const length = Number(request.headers.get("content-length") ?? "0");
	if (length > MAX_BODY) return reply(413, { error: "too large" });
	const packed = request.headers.get("x-body-encoding") === "deflate-raw";
	const bytes = await request.arrayBuffer();
	if (bytes.byteLength > MAX_BODY) return reply(413, { error: "too large" });
	let raw: string | null;
	try {
		raw = packed ? await inflate(bytes) : new TextDecoder().decode(bytes);
	} catch {
		return reply(400, { error: "can't unpack" });
	}
	if (raw === null) return reply(413, { error: "too large unpacked" });
	let body: Upload;
	try {
		body = JSON.parse(raw);
	} catch {
		return reply(400, { error: "not JSON" });
	}
	const problem = check(body);
	if (problem) return reply(400, { error: problem });
	const { success } = await env.UPLOADS.limit({ key: body.install });
	if (!success) return reply(429, { error: "slow down" });

	// Newest first in a listing: keys sort by a count down from far in the future.
	const order = (9_999_999_999_999 - Date.now()).toString().padStart(13, "0");
	const key = `u/${body.model}/${body.ios}/${body.app}/${body.install}/${order}-${crypto.randomUUID().slice(0, 8)}`;
	// Only the files are kept. A packed upload is kept packed, about a tenth of the space.
	const files = JSON.stringify({ files: body.files.map((f) => ({ name: f.name, text: f.text })) });
	const stored = packed ? await deflate(files) : files;
	await env.LOGS.put(key, stored, {
		expirationTtl: KEEP_SECONDS,
		metadata: { files: body.files.length, bytes: raw.length, encoding: packed ? "deflate-raw" : "json" },
	});
	return reply(200, { stored: body.files.length });
}

async function deflate(text: string): Promise<ArrayBuffer> {
	const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("deflate-raw"));
	return new Response(stream).arrayBuffer();
}

async function list(url: URL): Promise<Response> {
	const page = await env.LOGS.list({ prefix: "u/", cursor: url.searchParams.get("cursor") ?? undefined, limit: 1000 });
	return reply(200, {
		keys: page.keys.map((k) => ({ key: k.name, ...(k.metadata as object) })),
		cursor: page.list_complete ? null : page.cursor,
	});
}

export default {
	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "POST" && url.pathname === "/upload") return upload(request);
		if (url.pathname === "/health") return reply(200, { ok: true });
		if (!["/list", "/get", "/delete"].includes(url.pathname)) return reply(404, { error: "unknown path" });
		if (!isOwner(request)) return reply(401, { error: "owner only" });
		if (request.method === "GET" && url.pathname === "/list") return list(url);
		const key = url.searchParams.get("key") ?? "";
		if (!key.startsWith("u/")) return reply(400, { error: "bad key" });
		if (request.method === "GET" && url.pathname === "/get") {
			const { value, metadata } = await env.LOGS.getWithMetadata<{ encoding?: string }>(key, "arrayBuffer");
			if (value === null) return reply(404, { error: "no such upload" });
			const encoding = metadata?.encoding === "deflate-raw" ? "deflate-raw" : "json";
			return new Response(value, { headers: { "content-type": "application/octet-stream", "x-body-encoding": encoding } });
		}
		if (request.method === "POST" && url.pathname === "/delete") {
			await env.LOGS.delete(key);
			return reply(200, { deleted: key });
		}
		return reply(405, { error: "wrong method" });
	},
} satisfies ExportedHandler;
