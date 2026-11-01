#include <metal_stdlib>
using namespace metal;

struct PreviewUniforms {
    uint2 redOffset;
    uint2 blueOffset;
    float black;
    float white;
    float3 gains;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut previewVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    VertexOut out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = uv;
    return out;
}

// Crude half-resolution debayer for monitoring only. It reads the 2x2 Bayer block under
// each screen pixel; the sensor is landscape, so the image is rotated 90 degrees.
fragment float4 previewBayer(VertexOut in [[stage_in]],
                             texture2d<ushort, access::read> bayer [[texture(0)]],
                             constant PreviewUniforms &u [[buffer(0)]]) {
    uint2 size = uint2(bayer.get_width(), bayer.get_height());
    float2 rotated = float2(in.uv.y, 1.0 - in.uv.x);
    uint2 pixel = min(uint2(rotated * float2(size)), size - 2);
    uint2 block = pixel & ~uint2(1);

    float red = float(bayer.read(block + u.redOffset).r);
    float blue = float(bayer.read(block + u.blueOffset).r);
    float green = (float(bayer.read(block + uint2(u.redOffset.x, u.blueOffset.y)).r) +
                   float(bayer.read(block + uint2(u.blueOffset.x, u.redOffset.y)).r)) * 0.5;

    float3 linear = (float3(red, green, blue) - u.black) / max(u.white - u.black, 1.0);
    float3 balanced = saturate(linear * u.gains);
    return float4(pow(balanced, 1.0 / 2.2), 1.0);
}
