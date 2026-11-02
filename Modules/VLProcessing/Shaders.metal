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
    uint useLUT;  // 0 none, 1 Rec.709, 2 custom on log, 3 Rec.709 then custom.
    float lutSize;  // Of the custom LUT.
    uint overlay;  // 0 none, 1 zebras, 2 false color.
    float cropFraction;  // Share of the sensor height kept by the recording crop.
    float4 lutScale;
    float4 lutOffset;
    float4 bandsLow;  // Blue below, green from, green to, pink from.
    float4 bandsHigh;  // Pink to, yellow from, clip, size of the Rec.709 LUT.
    float2 viewOrigin;  // Top left of the part shown, as a share of the portrait picture.
    float viewScale;  // Share of the picture shown. Below 1 it reaches past the drawable's pixels.
    uint peaking;  // 1 marks fine detail, for judging focus.
    float2 peakStep;  // One drawable pixel at full view, in the image's coordinates.
    float peakThreshold;  // The edge strength peaking marks.
    float desqueeze;  // Widens the picture by narrowing its short side, with black beside it.
};

struct CropParams {
    float2 uvOffset;
    float2 uvScale;
};

struct DirectParams {
    int2 sourceOrigin;
    uint2 chromaStep;
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
        case 0:
        case 3: return encodeAppleLog(x);
        case 1: return encodeSLog3(x);
        default: return encodeLogC3(x);
    }
}

// White-balanced camera RGB to log Rec.2020.
static inline float3 cameraToLog(float3 rgb, constant ProcessParams &u) {
    float3 linear = float3(dot(u.matrixRow0.xyz, rgb), dot(u.matrixRow1.xyz, rgb),
                           dot(u.matrixRow2.xyz, rgb)) * u.exposure;
    return float3(encodeLog(linear.r, u.curve), encodeLog(linear.g, u.curve),
                  encodeLog(linear.b, u.curve));
}

// Debayers with Malvar-He-Cutler (demosaic 0) or bilinear (demosaic 1), converts to linear
// Rec.2020, applies exposure and encodes log.
static inline float3 logPixel(texture2d<ushort, access::read> raw, int2 p, int2 size,
                              constant ProcessParams &u) {
    bool redRow = (uint(p.y) & 1) == u.redOffset.y;
    bool redColumn = (uint(p.x) & 1) == u.redOffset.x;

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
    return cameraToLog(min(rgb, float3(u.clip)), u);
}

kernel void processRaw(texture2d<ushort, access::read> raw [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant ProcessParams &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    output.write(float4(logPixel(raw, int2(gid), size, u), 1.0), gid);
}

// Half-size monitor image built from whole 2x2 Bayer blocks, with no debayer.
kernel void processMonitor(texture2d<ushort, access::read> raw [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant ProcessParams &u [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    int2 block = int2(gid) * 2;
    int2 redAt = block + int2(u.redOffset);
    int2 blueAt = block + (int2(1) - int2(u.redOffset));
    float red = balancedSample(raw, redAt, size, u);
    float blue = balancedSample(raw, blueAt, size, u);
    float green = (balancedSample(raw, int2(redAt.x, blueAt.y), size, u) +
                   balancedSample(raw, int2(blueAt.x, redAt.y), size, u)) * 0.5;
    output.write(float4(cameraToLog(float3(red, green, blue), u), 1.0), gid);
}

// Rec.2020 non-constant luminance, 10-bit video range, MSB-aligned in 16 bits. Sampling on
// the output grid resizes the image and averages chroma when it is subsampled.
static inline float3 logSample(texture2d<float, access::sample> image, float2 uv) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    return image.sample(linearSampler, uv).rgb;
}

static inline float rec2020Luma(float3 rgb) {
    return dot(rgb, float3(0.2627, 0.6780, 0.0593));
}

static inline float msbAligned(float code) {
    return round(clamp(code, 4.0, 1019.0)) * 64.0 / 65535.0;
}

kernel void encodeLuma(texture2d<float, access::sample> image [[texture(0)]],
                       texture2d<float, access::write> luma [[texture(1)]],
                       constant CropParams &crop [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float2 uv = crop.uvOffset + crop.uvScale * (float2(gid) + 0.5) / float2(luma.get_width(), luma.get_height());
    float y = rec2020Luma(saturate(logSample(image, uv)));
    luma.write(float4(msbAligned(64.0 + 876.0 * y)), gid);
}

kernel void encodeChroma(texture2d<float, access::sample> image [[texture(0)]],
                         texture2d<float, access::write> chroma [[texture(1)]],
                         constant CropParams &crop [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float2 uv = crop.uvOffset + crop.uvScale * (float2(gid) + 0.5) / float2(chroma.get_width(), chroma.get_height());
    float3 rgb = saturate(logSample(image, uv));
    float y = rec2020Luma(rgb);
    float cb = (rgb.b - y) / 1.8814;
    float cr = (rgb.r - y) / 1.4746;
    chroma.write(float4(msbAligned(512.0 + 896.0 * cb), msbAligned(512.0 + 896.0 * cr), 0.0, 0.0), gid);
}

// Writes the encoder's planes straight from the Bayer data, with the same math per pixel as
// processRaw followed by encodeLuma and encodeChroma. Each thread covers one chroma sample.
kernel void processDirect(texture2d<ushort, access::read> raw [[texture(0)]],
                          texture2d<float, access::write> luma [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          constant ProcessParams &u [[buffer(0)]],
                          constant DirectParams &d [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    float3 total = float3(0.0);
    for (uint y = 0; y < d.chromaStep.y; y++) {
        for (uint x = 0; x < d.chromaStep.x; x++) {
            uint2 target = gid * d.chromaStep + uint2(x, y);
            float3 rgb = saturate(logPixel(raw, int2(target) + d.sourceOrigin, size, u));
            total += rgb;
            luma.write(float4(msbAligned(64.0 + 876.0 * rec2020Luma(rgb))), target);
        }
    }
    float3 rgb = total / float(d.chromaStep.x * d.chromaStep.y);
    float y = rec2020Luma(rgb);
    float cb = (rgb.b - y) / 1.8814;
    float cr = (rgb.r - y) / 1.4746;
    chroma.write(float4(msbAligned(512.0 + 896.0 * cb), msbAligned(512.0 + 896.0 * cr), 0.0, 0.0), gid);
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
                                texture3d<float> rec709 [[texture(1)]],
                                texture3d<float> custom [[texture(2)]],
                                constant MonitorParams &m [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float across = 0.5 + (in.uv.x - 0.5) * m.desqueeze;
    if (across < 0.0 || across > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float2 shown = m.viewOrigin + float2(across, in.uv.y) * m.viewScale;
    float2 rotated = float2(shown.y, 1.0 - shown.x);
    float3 logColor = image.sample(linearSampler, rotated).rgb;
    float3 color = logColor;
    if (m.useLUT == 1 || m.useLUT == 3) {
        float size = m.bandsHigh.w;
        color = rec709.sample(linearSampler, (saturate(color) * (size - 1.0) + 0.5) / size).rgb;
    }
    if (m.useLUT >= 2) {
        float3 normalized = saturate((color - m.lutOffset.rgb) * m.lutScale.rgb);
        float3 coordinate = (normalized * (m.lutSize - 1.0) + 0.5) / m.lutSize;
        color = custom.sample(linearSampler, coordinate).rgb;
    }

    float clip = m.bandsHigh.z;
    if (m.overlay == 1) {
        bool clipped = max(max(logColor.r, logColor.g), logColor.b) >= clip;
        if (clipped) {
            color = float3(fmod(in.position.x + in.position.y, 24.0) < 12.0 ? 1.0 : 0.0);
        }
    } else if (m.overlay == 2) {
        float luma = rec2020Luma(logColor);
        color = float3(luma);
        if (luma >= clip) {
            color = float3(1.0, 0.0, 0.0);
        } else if (luma < m.bandsLow.x) {
            color = float3(0.1, 0.2, 0.9);
        } else if (luma >= m.bandsLow.y && luma <= m.bandsLow.z) {
            color = float3(0.1, 0.8, 0.2);
        } else if (luma >= m.bandsLow.w && luma <= m.bandsHigh.x) {
            color = float3(1.0, 0.5, 0.75);
        } else if (luma >= m.bandsHigh.y) {
            color = float3(1.0, 0.9, 0.1);
        }
    }

    // Log luma against four neighbors a few sensor pixels away. Sharp edges stand out most.
    if (m.peaking != 0) {
        float edge = 4.0 * rec2020Luma(logColor);
        edge -= rec2020Luma(image.sample(linearSampler, rotated + float2(m.peakStep.x, 0)).rgb);
        edge -= rec2020Luma(image.sample(linearSampler, rotated - float2(m.peakStep.x, 0)).rgb);
        edge -= rec2020Luma(image.sample(linearSampler, rotated + float2(0, m.peakStep.y)).rgb);
        edge -= rec2020Luma(image.sample(linearSampler, rotated - float2(0, m.peakStep.y)).rgb);
        if (abs(edge) > m.peakThreshold) {
            color = float3(0.0, 1.0, 1.0);
        }
    }

    if (abs(rotated.y - 0.5) * 2.0 > m.cropFraction) {
        color *= 0.35;
    }
    return float4(color, 1.0);
}
