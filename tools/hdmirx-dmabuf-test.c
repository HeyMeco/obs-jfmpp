// Import rk_hdmirx capture buffers into the GPU (EGL dma-buf, R8 + GR88 planes),
// check the pixels against a CPU read, then time a YUV->RGB shader at the
// capture rate and dump one converted frame to hdmirx-frame.ppm.
//
// Build: gcc -O2 -Wall -o hdmirx-dmabuf-test hdmirx-dmabuf-test.c -lEGL -lGLESv2
// Run:   ./hdmirx-dmabuf-test [/dev/video0] [frames]   (close OBS first)

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define DRM_R8 FOURCC('R', '8', ' ', ' ')
#define DRM_GR88 FOURCC('G', 'R', '8', '8')
#define NBUF 4

struct plane {
	const char *name;
	uint32_t drm;
	int w, h, pitch, offset, src; // src = V4L2 plane holding this GPU plane
	int cpp;
};

struct buf {
	void *map[VIDEO_MAX_PLANES];
	size_t len[VIDEO_MAX_PLANES];
	int fd[VIDEO_MAX_PLANES];
	EGLImageKHR img[2];
	GLuint tex[2];
};

static EGLDisplay dpy;
static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;

static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static const char *fourcc_str(uint32_t f)
{
	static char s[5];
	memcpy(s, &f, 4);
	return s;
}

static void report_modifiers(uint32_t drm)
{
	PFNEGLQUERYDMABUFMODIFIERSEXTPROC query =
		(PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
	EGLuint64KHR mods[64];
	EGLBoolean ext[64];
	EGLint n = 0;

	if (!query || !query(dpy, drm, 64, mods, ext, &n)) {
		printf("  %s: eglQueryDmaBufModifiersEXT failed (0x%x)\n", fourcc_str(drm), eglGetError());
		return;
	}
	printf("  %s: %d modifier(s)%s\n", fourcc_str(drm), n, n ? "" : " (implicit/linear import only)");
	for (int i = 0; i < n; i++)
		printf("    0x%016llx%s%s\n", (unsigned long long)mods[i], mods[i] == 0 ? " LINEAR" : "",
		       ext[i] ? " external-only" : "");
}

// GPU planes for each capture format; returns the plane count, 0 if unsupported.
static int layout(const struct v4l2_pix_format_mplane *mp, struct plane *p)
{
	int w = mp->width, h = mp->height;
	int bpl0 = mp->plane_fmt[0].bytesperline;
	int split = mp->num_planes > 1;
	int bpl1 = split ? mp->plane_fmt[1].bytesperline : 0;
	int cw, ch, cpitch;

	switch (mp->pixelformat) {
	case V4L2_PIX_FMT_BGR24:
		p[0] = (struct plane){"BGR as R8", DRM_R8, w * 3, h, bpl0, 0, 0, 1};
		return 1;
	case V4L2_PIX_FMT_NV12:
	case V4L2_PIX_FMT_NV16:
	case V4L2_PIX_FMT_NV24:
		cw = mp->pixelformat == V4L2_PIX_FMT_NV24 ? w : w / 2;
		ch = mp->pixelformat == V4L2_PIX_FMT_NV12 ? h / 2 : h;
		cpitch = split ? bpl1 : (mp->pixelformat == V4L2_PIX_FMT_NV24 ? bpl0 * 2 : bpl0);
		p[0] = (struct plane){"Y as R8", DRM_R8, w, h, bpl0, 0, 0, 1};
		p[1] = (struct plane){"UV as GR88", DRM_GR88, cw, ch, cpitch, split ? 0 : bpl0 * h, split, 2};
		return 2;
	}
	return 0;
}

static GLuint import_plane(const struct plane *p, int fd, EGLImageKHR *img_out)
{
	EGLint attrs[] = {
		EGL_WIDTH, p->w,
		EGL_HEIGHT, p->h,
		EGL_LINUX_DRM_FOURCC_EXT, (EGLint)p->drm,
		EGL_DMA_BUF_PLANE0_FD_EXT, fd,
		EGL_DMA_BUF_PLANE0_OFFSET_EXT, p->offset,
		EGL_DMA_BUF_PLANE0_PITCH_EXT, p->pitch,
		EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0,
		EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0,
		EGL_NONE,
	};
	EGLImageKHR img = create_image(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	GLuint tex;
	GLenum err;

	if (img == EGL_NO_IMAGE_KHR)
		die("FAIL: eglCreateImage for %s %dx%d pitch %d offset %d: EGL error 0x%x", p->name, p->w, p->h,
		    p->pitch, p->offset, eglGetError());

	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	image_target(GL_TEXTURE_2D, img);
	if ((err = glGetError()) != GL_NO_ERROR)
		die("FAIL: glEGLImageTargetTexture2DOES(GL_TEXTURE_2D) for %s: GL error 0x%x "
		    "(format may be external-only)",
		    p->name, err);
	*img_out = img;
	return tex;
}

static GLuint compile(const char *vs_src, const char *fs_src)
{
	const char *src[2] = {vs_src, fs_src};
	GLenum type[2] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
	GLuint prog = glCreateProgram();
	GLint ok;
	char log[1024];

	for (int i = 0; i < 2; i++) {
		GLuint s = glCreateShader(type[i]);
		glShaderSource(s, 1, &src[i], NULL);
		glCompileShader(s);
		glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
		if (!ok) {
			glGetShaderInfoLog(s, sizeof(log), NULL, log);
			die("shader: %s", log);
		}
		glAttachShader(prog, s);
	}
	glBindAttribLocation(prog, 0, "pos");
	glLinkProgram(prog);
	glGetProgramiv(prog, GL_LINK_STATUS, &ok);
	if (!ok) {
		glGetProgramInfoLog(prog, sizeof(log), NULL, log);
		die("link: %s", log);
	}
	return prog;
}

static const char *vs = "attribute vec2 pos; varying highp vec2 uv;\n"
			"void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n";

// Copies texels 1:1 so the readback can be compared byte for byte.
static const char *fs_raw = "precision highp float; varying vec2 uv; uniform sampler2D t0;\n"
			    "void main() { vec4 c = texture2D(t0, uv); gl_FragColor = vec4(c.r, c.g, 0.0, 1.0); }\n";

// BT.709 limited range, Y in R8, Cb/Cr in GR88 (R = Cb, G = Cr).
static const char *fs_yuv = "precision highp float; varying vec2 uv; uniform sampler2D ty, tc;\n"
			    "void main() {\n"
			    "  float y = (texture2D(ty, uv).r - 16.0 / 255.0) * (255.0 / 219.0);\n"
			    "  vec2 c = (texture2D(tc, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);\n"
			    "  vec3 rgb = vec3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);\n"
			    "  gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);\n"
			    "}\n";

// Packed BGR24 imported as R8 at 3x width.
static const char *fs_bgr = "precision highp float; varying vec2 uv; uniform sampler2D ty; uniform float tw;\n"
			    "void main() {\n"
			    "  float x = floor(uv.x * tw / 3.0) * 3.0;\n"
			    "  float b = texture2D(ty, vec2((x + 0.5) / tw, uv.y)).r;\n"
			    "  float g = texture2D(ty, vec2((x + 1.5) / tw, uv.y)).r;\n"
			    "  float r = texture2D(ty, vec2((x + 2.5) / tw, uv.y)).r;\n"
			    "  gl_FragColor = vec4(r, g, b, 1.0);\n"
			    "}\n";

static void draw_quad(void)
{
	static const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
	glEnableVertexAttribArray(0);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

static GLuint make_target(int w, int h, GLuint *tex_out)
{
	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		die("FBO %dx%d incomplete", w, h);
	*tex_out = tex;
	return fbo;
}

// Render a plane 1:1 and compare every byte with what the CPU sees in the mapping.
static int verify_plane(const struct plane *p, GLuint tex, const uint8_t *cpu, GLuint prog)
{
	GLuint target, fbo = make_target(p->w, p->h, &target);
	uint8_t *px = malloc((size_t)p->w * p->h * 4);
	long bad = 0, first_x = -1, first_y = -1;

	glViewport(0, 0, p->w, p->h);
	glUseProgram(prog);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, tex);
	glUniform1i(glGetUniformLocation(prog, "t0"), 0);
	draw_quad();
	glReadPixels(0, 0, p->w, p->h, GL_RGBA, GL_UNSIGNED_BYTE, px);

	// Readback row 0 is texture row 0, which is the first row in memory.
	for (int y = 0; y < p->h; y++) {
		const uint8_t *row = cpu + p->offset + (size_t)y * p->pitch;
		for (int x = 0; x < p->w; x++) {
			const uint8_t *g = px + ((size_t)y * p->w + x) * 4;
			int ok = g[0] == row[x * p->cpp] && (p->cpp < 2 || g[1] == row[x * p->cpp + 1]);
			if (!ok && bad++ == 0) {
				first_x = x;
				first_y = y;
			}
		}
	}
	if (bad)
		printf("  %-11s %dx%d: FAIL, %ld texels differ (first at %ld,%ld)\n", p->name, p->w, p->h, bad,
		       first_x, first_y);
	else
		printf("  %-11s %dx%d pitch %d: OK, matches CPU bytes\n", p->name, p->w, p->h, p->pitch);

	free(px);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &target);
	return bad == 0;
}

static void write_ppm(const char *path, int w, int h)
{
	uint8_t *px = malloc((size_t)w * h * 4);
	FILE *f = fopen(path, "wb");
	if (!f)
		die("open %s: %s", path, strerror(errno));
	glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	for (size_t i = 0; i < (size_t)w * h; i++)
		fwrite(px + i * 4, 1, 3, f);
	fclose(f);
	free(px);
}

static int dequeue(int fd, struct v4l2_buffer *b, struct v4l2_plane *planes, int nplanes)
{
	struct pollfd pfd = {fd, POLLIN, 0};
	if (poll(&pfd, 1, 2000) <= 0)
		die("no frame within 2 s (signal lost?)");
	memset(b, 0, sizeof(*b));
	memset(planes, 0, sizeof(*planes) * VIDEO_MAX_PLANES);
	b->type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	b->memory = V4L2_MEMORY_MMAP;
	b->m.planes = planes;
	b->length = nplanes;
	if (xioctl(fd, VIDIOC_DQBUF, b) < 0)
		die("VIDIOC_DQBUF: %s", strerror(errno));
	return b->index;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/video0";
	int frames = argc > 2 ? atoi(argv[2]) : 300;
	struct v4l2_format fmt = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE};
	struct v4l2_requestbuffers req = {0};
	struct v4l2_plane planes[VIDEO_MAX_PLANES];
	struct v4l2_buffer b;
	struct plane gp[2];
	struct buf bufs[NBUF] = {0};
	int ngp, fd, nplanes, ok = 1;

	// --- EGL / GLES on the render node, no window needed ---
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	dpy = get_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL))
		die("eglInitialize failed (0x%x)", eglGetError());
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attrs);
	if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		die("GLES context failed (0x%x)", eglGetError());
	create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	image_target = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (!create_image || !image_target)
		die("EGLImage entry points missing");

	printf("GPU: %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
	printf("dma-buf import modifiers:\n");
	report_modifiers(DRM_R8);
	report_modifiers(DRM_GR88);

	// --- HDMI RX capture ---
	if ((fd = open(dev, O_RDWR | O_NONBLOCK)) < 0)
		die("open %s: %s", dev, strerror(errno));
	if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0)
		die("VIDIOC_G_FMT (multiplanar): %s", strerror(errno));
	struct v4l2_pix_format_mplane *mp = &fmt.fmt.pix_mp;
	nplanes = mp->num_planes;
	printf("capture: %ux%u %s, %d v4l2 plane(s), bytesperline %u\n", mp->width, mp->height,
	       fourcc_str(mp->pixelformat), nplanes, mp->plane_fmt[0].bytesperline);
	if (!(ngp = layout(mp, gp)))
		die("format %s not handled by this test (NV12/NV16/NV24/BGR3 only)", fourcc_str(mp->pixelformat));

	req.count = NBUF;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2)
		die("VIDIOC_REQBUFS: %s", strerror(errno));
	for (unsigned i = 0; i < req.count && i < NBUF; i++) {
		memset(&b, 0, sizeof(b));
		b.type = req.type;
		b.memory = req.memory;
		b.index = i;
		b.m.planes = planes;
		b.length = nplanes;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0)
			die("VIDIOC_QUERYBUF: %s", strerror(errno));
		for (int p = 0; p < nplanes; p++) {
			struct v4l2_exportbuffer exp = {.type = req.type, .index = i, .plane = p, .flags = O_RDONLY};
			bufs[i].len[p] = planes[p].length;
			bufs[i].map[p] = mmap(NULL, planes[p].length, PROT_READ, MAP_SHARED, fd, planes[p].m.mem_offset);
			if (bufs[i].map[p] == MAP_FAILED)
				die("mmap: %s", strerror(errno));
			if (xioctl(fd, VIDIOC_EXPBUF, &exp) < 0)
				die("VIDIOC_EXPBUF: %s", strerror(errno));
			bufs[i].fd[p] = exp.fd;
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0)
			die("VIDIOC_QBUF: %s", strerror(errno));
	}
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(fd, VIDIOC_STREAMON, &type) < 0)
		die("VIDIOC_STREAMON: %s", strerror(errno));

	// --- 1. import one frame and verify it byte for byte ---
	int idx = dequeue(fd, &b, planes, nplanes);
	double t0 = now_ms();
	for (int p = 0; p < ngp; p++)
		bufs[idx].tex[p] = import_plane(&gp[p], bufs[idx].fd[gp[p].src], &bufs[idx].img[p]);
	printf("import: OK (%.2f ms for %d plane(s), GL_TEXTURE_2D)\n", now_ms() - t0, ngp);

	GLuint raw = compile(vs, fs_raw);
	printf("verify:\n");
	for (int p = 0; p < ngp; p++)
		ok &= verify_plane(&gp[p], bufs[idx].tex[p], bufs[idx].map[gp[p].src], raw);
	xioctl(fd, VIDIOC_QBUF, &b);

	// --- 2. convert to RGB at capture rate ---
	int is_bgr = mp->pixelformat == V4L2_PIX_FMT_BGR24;
	GLuint conv = compile(vs, is_bgr ? fs_bgr : fs_yuv), out_tex;
	GLuint out = make_target(mp->width, mp->height, &out_tex);
	glUseProgram(conv);
	glUniform1i(glGetUniformLocation(conv, "ty"), 0);
	if (is_bgr)
		glUniform1f(glGetUniformLocation(conv, "tw"), (GLfloat)gp[0].w);
	else
		glUniform1i(glGetUniformLocation(conv, "tc"), 1);
	glViewport(0, 0, mp->width, mp->height);

	double start = 0, gpu_total = 0, gpu_max = 0;
	for (int i = 0; i < frames; i++) {
		idx = dequeue(fd, &b, planes, nplanes);
		if (i == 0)
			start = now_ms();
		if (!bufs[idx].tex[0])
			for (int p = 0; p < ngp; p++)
				bufs[idx].tex[p] = import_plane(&gp[p], bufs[idx].fd[gp[p].src], &bufs[idx].img[p]);
		double t = now_ms();
		for (int p = 0; p < ngp; p++) {
			glActiveTexture(GL_TEXTURE0 + p);
			glBindTexture(GL_TEXTURE_2D, bufs[idx].tex[p]);
			if (p == 1) { // chroma is subsampled for NV12/NV16
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			}
		}
		glBindFramebuffer(GL_FRAMEBUFFER, out);
		draw_quad();
		glFinish(); // the plugin will use a fence; this is the worst case
		double d = now_ms() - t;
		gpu_total += d;
		if (d > gpu_max)
			gpu_max = d;
		if (i == frames - 1)
			write_ppm("hdmirx-frame.ppm", mp->width, mp->height);
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0)
			die("VIDIOC_QBUF: %s", strerror(errno));
	}
	double secs = (now_ms() - start) / 1e3;
	printf("convert: %d frames in %.2f s = %.2f fps; GPU convert avg %.2f ms, max %.2f ms\n", frames, secs,
	       (frames - 1) / secs, gpu_total / frames, gpu_max);
	printf("wrote hdmirx-frame.ppm (%ux%u RGB)\n", mp->width, mp->height);

	xioctl(fd, VIDIOC_STREAMOFF, &type);
	printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL (pixel mismatch)");
	return ok ? 0 : 1;
}
