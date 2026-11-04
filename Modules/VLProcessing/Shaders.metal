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
    uint curve;  // The log curve to decode, as LogCurve's raw value.
    float4 toRec709Row0;  // Linear in the recorded gamut to linear Rec.709.
    float4 toRec709Row1;
    float4 toRec709Row2;
};

struct CropParams {
    float2 uvOffset;
    float2 uvScale;
};

// Must match LookParams in ProcessingPipeline.swift. What the encoder writes: the log image as
// recorded, or a look baked in, in the file's own YCbCr matrix.
struct LookParams {
    uint mode;  // 0 log, 1 Rec.709 view, 2 LUT on log, 3 Rec.709 view then LUT.
    uint curve;
    float lutSize;
    float unused;
    float4 lutScale;
    float4 lutOffset;
    float4 toRec709Row0;
    float4 toRec709Row1;
    float4 toRec709Row2;
    float4 luma;  // Kr, Kg, Kb of the file's matrix.
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

static inline float encodeSLog2(float x) {
    x = x / 0.9 * 155.0 / 219.0;
    float y = x >= 0.0 ? 0.432699 * log10(x + 0.037584) + 0.646596 : x * 5.0 + 0.030001222851889303;
    return (y * 876.0 + 64.0) / 1023.0;
}

static inline float encodeLogC4(float x) {
    if (x >= -0.01805699611991131) return (log2(2231.8263090676883 * x + 64.0) - 6.0) / 14.0 * 0.9071358748778103 + 0.09286412512218964;
    return (x + 0.01805699611991131) / 0.1135972086105891;
}

static inline float encodeCanonLog3(float x) {
    x = x / 0.9;
    if (x < -0.014) return -0.36726845 * log10(-x * 14.98325 + 1.0) + 0.12783901;
    if (x <= 0.014) return 1.9754798 * x + 0.12512219;
    return 0.36726845 * log10(x * 14.98325 + 1.0) + 0.12240537;
}

// Matches LogCurve's raw values.
static inline float encodeLog(float x, uint curve) {
    switch (curve) {
        case 0:
        case 3: return encodeAppleLog(x);
        case 1: return encodeSLog3(x);
        case 4: return encodeSLog2(x);
        case 5: return encodeLogC4(x);
        case 6: return encodeCanonLog3(x);
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

// The same decoders as LogCurve.decode, for the viewfinder.
static inline float decodeLog(float y, uint curve) {
    switch (curve) {
        case 0:
        case 3: {
            float knee = 47.28711236 * (0.01 + 0.05641088) * (0.01 + 0.05641088);
            if (y >= knee) return exp2((y - 0.69336945) / 0.08550479) - 0.00964052;
            if (y >= 0.0) return sqrt(y / 47.28711236) - 0.05641088;
            return -0.05641088;
        }
        case 1:
            if (y >= 171.2102946929 / 1023.0) return pow(10.0f, (y * 1023.0 - 420.0) / 261.5) * 0.19 - 0.01;
            return (y * 1023.0 - 95.0) * 0.01125 / (171.2102946929 - 95.0);
        case 4: {
            float v = (y * 1023.0 - 64.0) / 876.0;
            float x = v >= 0.030001222851889303 ? pow(10.0f, (v - 0.646596) / 0.432699) - 0.037584
                                                : (v - 0.030001222851889303) / 5.0;
            return x * 219.0 / 155.0 * 0.9;
        }
        case 5:
            if (y >= 0.0) return (exp2(14.0 * (y - 0.09286412512218964) / 0.9071358748778103 + 6.0) - 64.0) / 2231.8263090676883;
            return y * 0.1135972086105891 - 0.01805699611991131;
        case 6: {
            float x;
            if (y < 0.097465473) x = -(pow(10.0f, (0.12783901 - y) / 0.36726845) - 1.0) / 14.98325;
            else if (y <= 0.15277891) x = (y - 0.12512219) / 1.9754798;
            else x = (pow(10.0f, (y - 0.12240537) / 0.36726845) - 1.0) / 14.98325;
            return x * 0.9;
        }
        default:
            if (y > 5.367655 * 0.010591 + 0.092809) return (pow(10.0f, (y - 0.385537) / 0.247190) - 0.052272) / 5.555556;
            return (y - 0.092809) / 5.367655;
    }
}

// MonitorTransform.display: decode, convert to Rec.709, then roll highlights off to display white.
static inline float3 displayRec709(float3 logColor, uint curve, float4 row0, float4 row1, float4 row2) {
    float3 linear = float3(decodeLog(logColor.r, curve), decodeLog(logColor.g, curve),
                           decodeLog(logColor.b, curve));
    float3 rec709 = float3(dot(row0.xyz, linear), dot(row1.xyz, linear), dot(row2.xyz, linear));
    const float peak = 8.0;
    const float shoulderB = 0.82 * peak / (peak - 1.0);
    const float shoulderA = 0.18 + shoulderB;
    float3 scene = max(rec709, 0.0);
    float3 shaped = min(shoulderA * scene / (scene + shoulderB), 1.0);
    return pow(shaped, 1.0 / 2.4);
}

static inline float3 monitorDisplay(float3 logColor, constant MonitorParams &m) {
    return displayRec709(logColor, m.curve, m.toRec709Row0, m.toRec709Row1, m.toRec709Row2);
}

static inline float3 lookColor(float3 logColor, constant LookParams &k, texture3d<float> lut) {
    if (k.mode == 0) return logColor;
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float3 color = logColor;
    if (k.mode == 1 || k.mode == 3) {
        color = displayRec709(color, k.curve, k.toRec709Row0, k.toRec709Row1, k.toRec709Row2);
    }
    if (k.mode >= 2) {
        float3 normalized = saturate((color - k.lutOffset.rgb) * k.lutScale.rgb);
        color = lut.sample(linearSampler, (normalized * (k.lutSize - 1.0) + 0.5) / k.lutSize).rgb;
    }
    return saturate(color);
}

// Y, Cb and Cr in the file's matrix, as 10-bit video-range codes.
static inline float3 videoCodes(float3 rgb, constant LookParams &k) {
    float y = dot(rgb, k.luma.xyz);
    float cb = (rgb.b - y) / (2.0 * (1.0 - k.luma.z));
    float cr = (rgb.r - y) / (2.0 * (1.0 - k.luma.x));
    return float3(64.0 + 876.0 * y, 512.0 + 896.0 * cb, 512.0 + 896.0 * cr);
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
                       texture3d<float> lut [[texture(2)]],
                       constant CropParams &crop [[buffer(0)]],
                       constant LookParams &k [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float2 uv = crop.uvOffset + crop.uvScale * (float2(gid) + 0.5) / float2(luma.get_width(), luma.get_height());
    float3 codes = videoCodes(lookColor(saturate(logSample(image, uv)), k, lut), k);
    luma.write(float4(msbAligned(codes.x)), gid);
}

kernel void encodeChroma(texture2d<float, access::sample> image [[texture(0)]],
                         texture2d<float, access::write> chroma [[texture(1)]],
                         texture3d<float> lut [[texture(2)]],
                         constant CropParams &crop [[buffer(0)]],
                         constant LookParams &k [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float2 uv = crop.uvOffset + crop.uvScale * (float2(gid) + 0.5) / float2(chroma.get_width(), chroma.get_height());
    float3 codes = videoCodes(lookColor(saturate(logSample(image, uv)), k, lut), k);
    chroma.write(float4(msbAligned(codes.y), msbAligned(codes.z), 0.0, 0.0), gid);
}

// Writes the encoder's planes straight from the Bayer data, with the same math per pixel as
// processRaw followed by encodeLuma and encodeChroma. Each thread covers one chroma sample.
kernel void processDirect(texture2d<ushort, access::read> raw [[texture(0)]],
                          texture2d<float, access::write> luma [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          texture3d<float> lut [[texture(3)]],
                          constant ProcessParams &u [[buffer(0)]],
                          constant DirectParams &d [[buffer(1)]],
                          constant LookParams &k [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    float3 total = float3(0.0);
    for (uint y = 0; y < d.chromaStep.y; y++) {
        for (uint x = 0; x < d.chromaStep.x; x++) {
            uint2 target = gid * d.chromaStep + uint2(x, y);
            float3 rgb = saturate(logPixel(raw, int2(target) + d.sourceOrigin, size, u));
            total += rgb;
            luma.write(float4(msbAligned(videoCodes(lookColor(rgb, k, lut), k).x)), target);
        }
    }
    // The log average, then the look, as the full path samples the log image.
    float3 codes = videoCodes(lookColor(total / float(d.chromaStep.x * d.chromaStep.y), k, lut), k);
    chroma.write(float4(msbAligned(codes.y), msbAligned(codes.z), 0.0, 0.0), gid);
}

// One 4:4:4 pixel as 16-bit AYCbCr, for ProRes 4444. Codes keep their fraction, so the
// encoder gets its full 12 bits rather than 10. Video range is the 10-bit range scaled by 64.
static inline float4 packedPixel(float3 rgb, constant LookParams &k, texture3d<float> lut) {
    float3 codes = clamp(videoCodes(lookColor(rgb, k, lut), k), 4.0, 1019.0);
    return float4(1.0, codes * 64.0 / 65535.0);
}

kernel void encodePacked(texture2d<float, access::sample> image [[texture(0)]],
                         texture2d<float, access::write> packed [[texture(1)]],
                         texture3d<float> lut [[texture(2)]],
                         constant CropParams &crop [[buffer(0)]],
                         constant LookParams &k [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float2 uv = crop.uvOffset + crop.uvScale * (float2(gid) + 0.5) / float2(packed.get_width(), packed.get_height());
    packed.write(packedPixel(saturate(logSample(image, uv)), k, lut), gid);
}

// The efficient path for packed 4:4:4: one thread per pixel, the same math as processDirect.
kernel void processDirectPacked(texture2d<ushort, access::read> raw [[texture(0)]],
                                texture2d<float, access::write> packed [[texture(1)]],
                                texture3d<float> lut [[texture(2)]],
                                constant ProcessParams &u [[buffer(0)]],
                                constant DirectParams &d [[buffer(1)]],
                                constant LookParams &k [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    packed.write(packedPixel(saturate(logPixel(raw, int2(gid) + d.sourceOrigin, size, u)), k, lut), gid);
}

// A decoded frame, 16-bit AYCbCr in video range, back to the log RGB image the encoder was given.
// `luma` names the matrix it was written in.
kernel void decodeVideo(texture2d<float, access::read> frame [[texture(0)]],
                        texture2d<float, access::write> image [[texture(1)]],
                        constant float4 &luma [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float3 codes = frame.read(gid).gba * 65535.0 / 64.0;
    float y = (codes.x - 64.0) / 876.0;
    float cb = (codes.y - 512.0) / 896.0;
    float cr = (codes.z - 512.0) / 896.0;
    float r = y + 2.0 * (1.0 - luma.x) * cr;
    float b = y + 2.0 * (1.0 - luma.z) * cb;
    float g = (y - luma.x * r - luma.z * b) / luma.y;
    image.write(float4(saturate(float3(r, g, b)), 1.0), gid);
}

// The look on a smaller copy of the log image, for the export preview, turned upright by the
// take's rotation in clockwise quarter turns.
kernel void lookPreview(texture2d<float, access::sample> image [[texture(0)]],
                        texture2d<float, access::write> output [[texture(1)]],
                        texture3d<float> lut [[texture(2)]],
                        constant LookParams &k [[buffer(0)]],
                        constant uint &turns [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    if (turns == 1) uv = float2(uv.y, 1.0 - uv.x);
    else if (turns == 2) uv = 1.0 - uv;
    else if (turns == 3) uv = float2(1.0 - uv.y, uv.x);
    output.write(float4(lookColor(saturate(logSample(image, uv)), k, lut), 1.0), gid);
}

// Only for tests, which compare the viewfinder's math with MonitorTransform.display.
kernel void monitorTransformTest(texture2d<float, access::read> image [[texture(0)]],
                                 texture2d<float, access::write> output [[texture(1)]],
                                 constant MonitorParams &m [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(monitorDisplay(image.read(gid).rgb, m), 1.0), gid);
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

// The look the viewfinder shows, before its tools: log, the Rec.709 view, a LUT on log, or the
// view then a LUT. The scopes measure the same.
static inline float3 monitorLook(float3 logColor, constant MonitorParams &m, texture3d<float> custom) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float3 color = logColor;
    if (m.useLUT == 1 || m.useLUT == 3) {
        color = monitorDisplay(saturate(color), m);
    }
    if (m.useLUT >= 2) {
        float3 normalized = saturate((color - m.lutOffset.rgb) * m.lutScale.rgb);
        float3 coordinate = (normalized * (m.lutSize - 1.0) + 0.5) / m.lutSize;
        color = custom.sample(linearSampler, coordinate).rgb;
    }
    return color;
}

// Must match ScopeParams in ScopeMeter.swift.
struct ScopeParams {
    uint columns;  // Across the picture as held.
    uint rows;  // Down it.
    uint turns;  // Clockwise quarter turns from the portrait screen to the hold.
    uint levels;  // Bins from black to white, and across the vectorscope.
};

// Counts a grid of the picture into scope bins: for each column across the picture as held, how
// many samples sit at each level of luma, red, green and blue, plus a histogram of each and the
// vectorscope's Cb and Cr in Rec.709. Atomic adds, since many threads land in one bin.
kernel void scopeBins(texture2d<float, access::sample> image [[texture(0)]],
                      texture3d<float> custom [[texture(2)]],
                      constant MonitorParams &m [[buffer(0)]],
                      constant ScopeParams &s [[buffer(1)]],
                      device atomic_uint *wave [[buffer(2)]],
                      device atomic_uint *vector [[buffer(3)]],
                      device atomic_uint *histogram [[buffer(4)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= s.columns || gid.y >= s.rows) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 held = (float2(gid) + 0.5) / float2(s.columns, s.rows);
    // Back to the portrait screen, then to the landscape image, as the viewfinder turns it.
    float2 screen = held;
    if (s.turns == 1) {
        screen = float2(1.0 - held.y, held.x);
    } else if (s.turns == 2) {
        screen = 1.0 - held;
    } else if (s.turns == 3) {
        screen = float2(held.y, 1.0 - held.x);
    }
    float2 rotated = float2(screen.y, 1.0 - screen.x);
    float3 color = saturate(monitorLook(image.sample(linearSampler, rotated).rgb, m, custom));
    float y = dot(color, float3(0.2126, 0.7152, 0.0722));
    float top = float(s.levels - 1);
    uint4 level = uint4(round(float4(y, color) * top));
    for (uint channel = 0; channel < 4; channel++) {
        atomic_fetch_add_explicit(&wave[(channel * s.levels + level[channel]) * s.columns + gid.x], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&histogram[channel * s.levels + level[channel]], 1, memory_order_relaxed);
    }
    float cb = (color.b - y) / 1.8556;
    float cr = (color.r - y) / 1.5748;
    uint across = uint(clamp(round((cb + 0.5) * top), 0.0, top));
    uint up = uint(clamp(round((0.5 - cr) * top), 0.0, top));
    atomic_fetch_add_explicit(&vector[up * s.levels + across], 1, memory_order_relaxed);
}

// Shows the log image, optionally through the Rec.709 LUT. The sensor is landscape, so the
// image is rotated 90 degrees for the portrait screen.
fragment float4 monitorFragment(VertexOut in [[stage_in]],
                                texture2d<float> image [[texture(0)]],
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
    float3 color = monitorLook(logColor, m, custom);

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
