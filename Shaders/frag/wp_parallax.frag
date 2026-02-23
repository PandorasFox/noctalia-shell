// ===== wp_parallax.frag =====
// Single-texture parallax shader for scrolling wallpaper mode.
// Crops the image to fill the screen, then offsets UVs based on
// scrollU/scrollV (0-100) so the viewport pans across the image.
#version 450

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float scrollU;       // Horizontal scroll position (0-100)
    float scrollV;       // Vertical scroll position (0-100)
    float imageWidth;    // Source image width
    float imageHeight;   // Source image height
    float screenWidth;   // Screen width
    float screenHeight;  // Screen height
} ubuf;

void main() {
    vec2 uv = qt_TexCoord0;

    // Compute crop scale (same as fill/cover mode)
    float scale = max(ubuf.screenWidth / ubuf.imageWidth, ubuf.screenHeight / ubuf.imageHeight);
    vec2 scaledSize = vec2(ubuf.imageWidth, ubuf.imageHeight) * scale;

    // Excess image area beyond the screen in UV space
    vec2 excess = (scaledSize - vec2(ubuf.screenWidth, ubuf.screenHeight)) / scaledSize;

    // Map scroll position (0-100) to UV offset within the excess range
    vec2 scrollOffset = vec2(ubuf.scrollU, ubuf.scrollV) / 100.0;

    // Final UV: scale down to visible portion, then offset by scroll position
    vec2 transformedUV = uv * (vec2(1.0) - excess) + excess * scrollOffset;

    // Clamp to valid range (safety)
    transformedUV = clamp(transformedUV, vec2(0.0), vec2(1.0));

    fragColor = texture(source, transformedUV) * ubuf.qt_Opacity;
}
