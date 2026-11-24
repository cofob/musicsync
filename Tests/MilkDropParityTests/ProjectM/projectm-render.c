// Renders a .milk preset with libprojectM 4 offscreen (CGL, OpenGL 4.1 core, FBO) at 256×192, with the audio of
// ParityTests.audio(f) on both channels, and writes the asked frames as <outdir>/<frame>.png (rows top first).
// Usage: projectm-render <preset.milk> <outdir> <frame,frame,...> [texture folder...]
// Build with scripts/projectm-reference.sh, which also patches projectM for fixed time steps and random values.
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <math.h>
#include <projectM-4/projectM.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { W = 256, H = 192, SAMPLES = 1024 };
extern unsigned int projectm_reference_fbo;

static void failed(const char* file, const char* message, void* data) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}

static int savePNG(const unsigned char* rgba, const char* path) {
    CFDataRef data = CFDataCreate(NULL, rgba, W * H * 4);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(W, H, 8, 32, W * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast, provider, NULL,
                                     false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int ok = dest != NULL;
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CFRelease(url);
    CGImageRelease(image);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return ok;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <preset.milk> <outdir> <frame,frame,...> [texture folder...]\n", argv[0]);
        return 1;
    }
    int keep[1024], count = 0, last = 0;
    for (char* s = strtok(argv[3], ","); s && count < 1024; s = strtok(NULL, ",")) {
        keep[count] = atoi(s);
        if (keep[count] > last) last = keep[count];
        count++;
    }

    CGLPixelFormatAttribute attributes[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0};
    CGLPixelFormatObj format;
    GLint formats;
    CGLContextObj context;
    if (CGLChoosePixelFormat(attributes, &format, &formats) || !format || CGLCreateContext(format, NULL, &context)) {
        fprintf(stderr, "no OpenGL 4.1 core context\n");
        return 3;
    }
    CGLSetCurrentContext(context);
    GLuint fbo, color;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenRenderbuffers(1, &color);
    glBindRenderbuffer(GL_RENDERBUFFER, color);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "framebuffer incomplete\n");
        return 3;
    }
    projectm_reference_fbo = fbo;

    projectm_handle pm = projectm_create();
    if (!pm) {
        fprintf(stderr, "projectm_create failed\n");
        return 3;
    }
    if (argc > 4) projectm_set_texture_search_paths(pm, (const char**)argv + 4, (size_t)(argc - 4));
    projectm_set_window_size(pm, W, H);
    projectm_set_mesh_size(pm, 48, 36);
    projectm_set_fps(pm, 60);
    projectm_set_preset_locked(pm, true);
    projectm_set_hard_cut_enabled(pm, false);
    projectm_set_preset_duration(pm, 1e6);
    projectm_set_preset_switch_failed_event_callback(pm, failed, NULL);
    srand(1);
    projectm_load_preset_file(pm, argv[1], false);

    static float pcm[SAMPLES * 2];
    static unsigned char pixels[W * H * 4], rows[W * H * 4];
    char path[4096];
    for (int f = 0; f < last; f++) {
        for (int i = 0; i < SAMPLES; i++) {
            double b = floor(128 + 100 * sin((double)(f * SAMPLES + i) * 0.05));
            pcm[2 * i] = pcm[2 * i + 1] = (float)((b - 128) / 128);
        }
        projectm_pcm_add_float(pm, pcm, SAMPLES, PROJECTM_STEREO);
        projectm_opengl_render_frame(pm);
        int wanted = 0;
        for (int k = 0; k < count; k++) wanted |= keep[k] == f + 1;
        if (!wanted) continue;
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        for (int y = 0; y < H; y++) memcpy(rows + y * W * 4, pixels + (H - 1 - y) * W * 4, W * 4);
        snprintf(path, sizeof path, "%s/%d.png", argv[2], f + 1);
        if (!savePNG(rows, path)) {
            fprintf(stderr, "cannot write %s\n", path);
            return 4;
        }
    }
    GLenum error = glGetError();
    projectm_destroy(pm);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(format);
    if (error != GL_NO_ERROR) fprintf(stderr, "OpenGL error 0x%x\n", error);
    return 0;
}
