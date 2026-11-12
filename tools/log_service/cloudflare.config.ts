import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// VibeLog's test log service. Phones that opted in upload small text files; the owner's computer
// pulls them with tools/pull_logs.py. See docs/decisions/log-service.md.
export default defineConfig({
	worker: {
		name: "vibelog-logs",
		compatibilityDate: "2026-11-10",
		entrypoint,
		env: {
			// Each upload, keyed by phone model, iOS, app version and anonymous install.
			LOGS: bindings.kv(),
			// Comma-separated codes a tester types into the app.
			INVITE_CODES: bindings.secret(),
			// The owner's key for listing, fetching and deleting uploads.
			ADMIN_TOKEN: bindings.secret(),
			// At most ten uploads a minute from one install.
			UPLOADS: bindings.rateLimit({ namespace: "1001", simple: { limit: 10, period: 60 } }),
		},
	},
});
