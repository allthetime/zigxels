/// Minimal OpenGL 3.3 Core bindings loaded via SDL_GL_GetProcAddress.
/// Only the functions needed for fullscreen-quad + texture upload + shader pipeline.
const SDL = @import("sdl2");

// --- GL Types ---
pub const GLuint = c_uint;
pub const GLint = c_int;
pub const GLenum = c_uint;
pub const GLsizei = c_int;
pub const GLboolean = u8;
pub const GLchar = u8;
pub const GLfloat = f32;
pub const GLsizeiptr = isize;
pub const GLbitfield = c_uint;

// --- GL Constants ---
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

pub const GL_TRIANGLES: GLenum = 0x0004;

pub const GL_BYTE: GLenum = 0x1400;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_FLOAT: GLenum = 0x1406;

pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_TEXTURE1: GLenum = 0x84C1;

pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;

pub const GL_RGBA: GLenum = 0x1908;
pub const GL_BGRA: GLenum = 0x80E1;
pub const GL_RGBA8: GLenum = 0x8058;
pub const GL_RED: GLenum = 0x1903;
pub const GL_R8: GLenum = 0x8229;
pub const GL_RG: GLenum = 0x8227;
pub const GL_RG8: GLenum = 0x822B;

pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;

pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;

pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x4000;

pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;

pub const GL_NO_ERROR: GLenum = 0;
pub const GL_INVALID_ENUM: GLenum = 0x0500;
pub const GL_INVALID_VALUE: GLenum = 0x0501;
pub const GL_INVALID_OPERATION: GLenum = 0x0502;

// --- Function pointer types ---
const GenTexturesProc = *const fn (GLsizei, [*]GLuint) callconv(.c) void;
const BindTextureProc = *const fn (GLenum, GLuint) callconv(.c) void;
const TexParameteriProc = *const fn (GLenum, GLenum, GLint) callconv(.c) void;
const TexImage2DProc = *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void;
const TexSubImage2DProc = *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void;
const ActiveTextureProc = *const fn (GLenum) callconv(.c) void;
const DeleteTexturesProc = *const fn (GLsizei, [*]const GLuint) callconv(.c) void;

const CreateShaderProc = *const fn (GLenum) callconv(.c) GLuint;
const ShaderSourceProc = *const fn (GLuint, GLsizei, [*]const [*]const GLchar, ?[*]const GLint) callconv(.c) void;
const CompileShaderProc = *const fn (GLuint) callconv(.c) void;
const GetShaderivProc = *const fn (GLuint, GLenum, *GLint) callconv(.c) void;
const GetShaderInfoLogProc = *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void;
const DeleteShaderProc = *const fn (GLuint) callconv(.c) void;

const CreateProgramProc = *const fn () callconv(.c) GLuint;
const AttachShaderProc = *const fn (GLuint, GLuint) callconv(.c) void;
const LinkProgramProc = *const fn (GLuint) callconv(.c) void;
const UseProgramProc = *const fn (GLuint) callconv(.c) void;
const GetProgramivProc = *const fn (GLuint, GLenum, *GLint) callconv(.c) void;
const GetProgramInfoLogProc = *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void;
const DeleteProgramProc = *const fn (GLuint) callconv(.c) void;
const GetUniformLocationProc = *const fn (GLuint, [*:0]const GLchar) callconv(.c) GLint;
const Uniform1iProc = *const fn (GLint, GLint) callconv(.c) void;
const Uniform1fProc = *const fn (GLint, GLfloat) callconv(.c) void;
const Uniform2fProc = *const fn (GLint, GLfloat, GLfloat) callconv(.c) void;

const GenVertexArraysProc = *const fn (GLsizei, [*]GLuint) callconv(.c) void;
const BindVertexArrayProc = *const fn (GLuint) callconv(.c) void;
const DeleteVertexArraysProc = *const fn (GLsizei, [*]const GLuint) callconv(.c) void;
const GenBuffersProc = *const fn (GLsizei, [*]GLuint) callconv(.c) void;
const BindBufferProc = *const fn (GLenum, GLuint) callconv(.c) void;
const BufferDataProc = *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void;
const DeleteBuffersProc = *const fn (GLsizei, [*]const GLuint) callconv(.c) void;

const EnableVertexAttribArrayProc = *const fn (GLuint) callconv(.c) void;
const VertexAttribPointerProc = *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void;

const DrawArraysProc = *const fn (GLenum, GLint, GLsizei) callconv(.c) void;

const ViewportProc = *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void;
const ClearProc = *const fn (GLbitfield) callconv(.c) void;
const ClearColorProc = *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void;
const GetErrorProc = *const fn () callconv(.c) GLenum;
const PixelStoreiProc = *const fn (GLenum, GLint) callconv(.c) void;

// --- Loaded function pointers ---
pub var genTextures: GenTexturesProc = undefined;
pub var bindTexture: BindTextureProc = undefined;
pub var texParameteri: TexParameteriProc = undefined;
pub var texImage2D: TexImage2DProc = undefined;
pub var texSubImage2D: TexSubImage2DProc = undefined;
pub var activeTexture: ActiveTextureProc = undefined;
pub var deleteTextures: DeleteTexturesProc = undefined;

pub var createShader: CreateShaderProc = undefined;
pub var shaderSource: ShaderSourceProc = undefined;
pub var compileShader: CompileShaderProc = undefined;
pub var getShaderiv: GetShaderivProc = undefined;
pub var getShaderInfoLog: GetShaderInfoLogProc = undefined;
pub var deleteShader: DeleteShaderProc = undefined;

pub var createProgram: CreateProgramProc = undefined;
pub var attachShader: AttachShaderProc = undefined;
pub var linkProgram: LinkProgramProc = undefined;
pub var useProgram: UseProgramProc = undefined;
pub var getProgramiv: GetProgramivProc = undefined;
pub var getProgramInfoLog: GetProgramInfoLogProc = undefined;
pub var deleteProgram: DeleteProgramProc = undefined;
pub var getUniformLocation: GetUniformLocationProc = undefined;
pub var uniform1i: Uniform1iProc = undefined;
pub var uniform1f: Uniform1fProc = undefined;
pub var uniform2f: Uniform2fProc = undefined;

pub var genVertexArrays: GenVertexArraysProc = undefined;
pub var bindVertexArray: BindVertexArrayProc = undefined;
pub var deleteVertexArrays: DeleteVertexArraysProc = undefined;
pub var genBuffers: GenBuffersProc = undefined;
pub var bindBuffer: BindBufferProc = undefined;
pub var bufferData: BufferDataProc = undefined;
pub var deleteBuffers: DeleteBuffersProc = undefined;

pub var enableVertexAttribArray: EnableVertexAttribArrayProc = undefined;
pub var vertexAttribPointer: VertexAttribPointerProc = undefined;

pub var drawArrays: DrawArraysProc = undefined;

pub var viewport: ViewportProc = undefined;
pub var clear: ClearProc = undefined;
pub var clearColor: ClearColorProc = undefined;
pub var getError: GetErrorProc = undefined;
pub var pixelStorei: PixelStoreiProc = undefined;

fn load(name: [:0]const u8) ?*const anyopaque {
    return SDL.gl.getProcAddress(name);
}

fn loadFn(comptime T: type, name: [:0]const u8) T {
    if (load(name)) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    @panic("Failed to load GL function");
}

pub fn init() void {
    genTextures = loadFn(GenTexturesProc, "glGenTextures");
    bindTexture = loadFn(BindTextureProc, "glBindTexture");
    texParameteri = loadFn(TexParameteriProc, "glTexParameteri");
    texImage2D = loadFn(TexImage2DProc, "glTexImage2D");
    texSubImage2D = loadFn(TexSubImage2DProc, "glTexSubImage2D");
    activeTexture = loadFn(ActiveTextureProc, "glActiveTexture");
    deleteTextures = loadFn(DeleteTexturesProc, "glDeleteTextures");

    createShader = loadFn(CreateShaderProc, "glCreateShader");
    shaderSource = loadFn(ShaderSourceProc, "glShaderSource");
    compileShader = loadFn(CompileShaderProc, "glCompileShader");
    getShaderiv = loadFn(GetShaderivProc, "glGetShaderiv");
    getShaderInfoLog = loadFn(GetShaderInfoLogProc, "glGetShaderInfoLog");
    deleteShader = loadFn(DeleteShaderProc, "glDeleteShader");

    createProgram = loadFn(CreateProgramProc, "glCreateProgram");
    attachShader = loadFn(AttachShaderProc, "glAttachShader");
    linkProgram = loadFn(LinkProgramProc, "glLinkProgram");
    useProgram = loadFn(UseProgramProc, "glUseProgram");
    getProgramiv = loadFn(GetProgramivProc, "glGetProgramiv");
    getProgramInfoLog = loadFn(GetProgramInfoLogProc, "glGetProgramInfoLog");
    deleteProgram = loadFn(DeleteProgramProc, "glDeleteProgram");
    getUniformLocation = loadFn(GetUniformLocationProc, "glGetUniformLocation");
    uniform1i = loadFn(Uniform1iProc, "glUniform1i");
    uniform1f = loadFn(Uniform1fProc, "glUniform1f");
    uniform2f = loadFn(Uniform2fProc, "glUniform2f");

    genVertexArrays = loadFn(GenVertexArraysProc, "glGenVertexArrays");
    bindVertexArray = loadFn(BindVertexArrayProc, "glBindVertexArray");
    deleteVertexArrays = loadFn(DeleteVertexArraysProc, "glDeleteVertexArrays");
    genBuffers = loadFn(GenBuffersProc, "glGenBuffers");
    bindBuffer = loadFn(BindBufferProc, "glBindBuffer");
    bufferData = loadFn(BufferDataProc, "glBufferData");
    deleteBuffers = loadFn(DeleteBuffersProc, "glDeleteBuffers");

    enableVertexAttribArray = loadFn(EnableVertexAttribArrayProc, "glEnableVertexAttribArray");
    vertexAttribPointer = loadFn(VertexAttribPointerProc, "glVertexAttribPointer");

    drawArrays = loadFn(DrawArraysProc, "glDrawArrays");

    viewport = loadFn(ViewportProc, "glViewport");
    clear = loadFn(ClearProc, "glClear");
    clearColor = loadFn(ClearColorProc, "glClearColor");
    getError = loadFn(GetErrorProc, "glGetError");
    pixelStorei = loadFn(PixelStoreiProc, "glPixelStorei");
}
