#include <metal_stdlib>
using namespace metal;

// Must match ProcessParams in ProcessingPipeline.swift.
struct ProcessParams {
    float4 matrixRow0;
    float4 matrixRow1;
    float4 matrixRow2;
    float4 cfaGain;  // Indexed by (x & 1) + 2 * (y & 1).
    uint2 redOffset;
    uint curve;
    uint demosaic;
    float black;
    float scale;
    float clip;
    float exposure;
};

struct MonitorParams {
    uint useLUT;
    float lutSize;
};

static inline int mirrored(int value, int size) {
    if (value < 0) return -value;
    if (value >= size) return 2 * size - 2 - value;
    return value;
}

// One Bayer sample after black level, normalization and white balance. Everything clips at
// the same level so saturated areas stay neutral rather than turning pink.
static inline float balancedSample(texture2d<ushort, access::read> raw, int2 position, int2 size,
                                   constant ProcessParams &u) {
    uint2 coordinate = uint2(mirrored(position.x, size.x), mirrored(position.y, size.y));
    uint channel = (coordinate.x & 1) + ((coordinate.y & 1) << 1);
    float value = (float(raw.read(coordinate).r) - u.black) * u.scale * u.cfaGain[channel];
    return min(value, u.clip);
}

static inline float encodeAppleLog(float x) {
    if (x >= 0.01) return 0.08550479 * log2(x + 0.00964052) + 0.69336945;
    if (x >= -0.05641088) return 47.28711236 * (x + 0.05641088) * (x + 0.05641088);
    return 0.0;
}

static inline float encodeSLog3(float x) {
    if (x >= 0.01125) return (420.0 + log10((x + 0.01) / 0.19) * 261.5) / 1023.0;
    return (x * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0;
}

static inline float encodeLogC3(float x) {
    if (x > 0.010591) return 0.247190 * log10(5.555556 * x + 0.052272) + 0.385537;
    return 5.367655 * x + 0.092809;
}

static inline float encodeLog(float x, uint curve) {
    switch (curve) {
        case 0: return encodeAppleLog(x);
        case 1: return encodeSLog3(x);
        default: return encodeLogC3(x);
    }
}

// Debayers with Malvar-He-Cutler (demosaic 0) or bilinear (demosaic 1), converts to linear
// Rec.2020, applies exposure and encodes log.
kernel void processRaw(texture2d<ushort, access::read> raw [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant ProcessParams &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    int2 p = int2(gid);
    bool redRow = (gid.y & 1) == u.redOffset.y;
    bool redColumn = (gid.x & 1) == u.redOffset.x;

#define S(dx, dy) balancedSample(raw, p + int2(dx, dy), size, u)
    float center = S(0, 0);
    float horizontal = S(-1, 0) + S(1, 0);
    float vertical = S(0, -1) + S(0, 1);
    float diagonal = S(-1, -1) + S(1, -1) + S(-1, 1) + S(1, 1);
#undef S

    float greenAtColor;
    float oppositeColor;
    float inRow;
    float inColumn;

    if (u.demosaic == 0) {
        float farHorizontal = balancedSample(raw, p + int2(-2, 0), size, u) +
                              balancedSample(raw, p + int2(2, 0), size, u);
        float farVertical = balancedSample(raw, p + int2(0, -2), size, u) +
                            balancedSample(raw, p + int2(0, 2), size, u);
        float far = farHorizontal + farVertical;
        greenAtColor = (4.0 * center + 2.0 * (horizontal + vertical) - far) / 8.0;
        oppositeColor = (6.0 * center + 2.0 * diagonal - 1.5 * far) / 8.0;
        inRow = (5.0 * center + 4.0 * horizontal - diagonal - farHorizontal + 0.5 * farVertical) / 8.0;
        inColumn = (5.0 * center + 4.0 * vertical - diagonal - farVertical + 0.5 * farHorizontal) / 8.0;
    } else {
        greenAtColor = (horizontal + vertical) * 0.25;
        oppositeColor = diagonal * 0.25;
        inRow = horizontal * 0.5;
        inColumn = vertical * 0.5;
    }

    float3 rgb;
    if (redRow && redColumn) {
        rgb = float3(center, greenAtColor, oppositeColor);
    } else if (!redRow && !redColumn) {
        rgb = float3(oppositeColor, greenAtColor, center);
    } else if (redRow) {
        rgb = float3(inRow, center, inColumn);
    } else {
        rgb = float3(inColumn, center, inRow);
    }
    rgb = min(rgb, float3(u.clip));

    float3 linear = float3(dot(u.matrixRow0.xyz, rgb), dot(u.matrixRow1.xyz, rgb),
                           dot(u.matrixRow2.xyz, rgb)) * u.exposure;
    float3 encoded = float3(encodeLog(linear.r, u.curve), encodeLog(linear.g, u.curve),
                            encodeLog(linear.b, u.curve));
    output.write(float4(encoded, 1.0), gid);
}

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut monitorVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    VertexOut out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = uv;
    return out;
}

// Shows the log image, optionally through the Rec.709 LUT. The sensor is landscape, so the
// image is rotated 90 degrees for the portrait screen.
fragment float4 monitorFragment(VertexOut in [[stage_in]],
                                texture2d<float> image [[texture(0)]],
                                texture3d<float> lut [[texture(1)]],
                                constant MonitorParams &m [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 rotated = float2(in.uv.y, 1.0 - in.uv.x);
    float3 color = image.sample(linearSampler, rotated).rgb;
    if (m.useLUT != 0) {
        float3 coordinate = (saturate(color) * (m.lutSize - 1.0) + 0.5) / m.lutSize;
        color = lut.sample(linearSampler, coordinate).rgb;
    }
    return float4(color, 1.0);
}
