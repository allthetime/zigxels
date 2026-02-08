const std = @import("std");
const gl = @import("gl.zig");

// --- Embedded shaders (no file I/O needed) ---

const vert_source: [:0]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 TexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    TexCoord = aTexCoord;
    \\}
;

const frag_source: [:0]const u8 =
    \\#version 330 core
    \\in vec2 TexCoord;
    \\out vec4 FragColor;
    \\
    \\uniform sampler2D u_color;
    \\uniform sampler2D u_effects;
    \\uniform vec2 u_resolution;
    \\uniform float u_time;
    \\
    \\const float BIT_BLOOM     = 1.0;
    \\const float BIT_BLUR      = 2.0;
    \\const float BIT_DISTORT   = 4.0;
    \\const float BIT_GLOW      = 8.0;
    \\const float BIT_HEAT      = 16.0;
    \\const float BIT_CHROMATIC = 32.0;
    \\const float BIT_DISSOLVE  = 64.0;
    \\
    \\bool hasFlag(float effects, float flag) {
    \\    return mod(floor(effects / flag), 2.0) >= 1.0;
    \\}
    \\
    \\float hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\
    \\// Separable gaussian: 1D horizontal + vertical combined
    \\vec4 fastBlur(vec2 uv, float radius) {
    \\    vec2 texel = 1.0 / u_resolution;
    \\    vec4 sum = texture(u_color, uv);
    \\    float total = 1.0;
    \\    for (float i = 1.0; i <= radius; i += 1.0) {
    \\        float w = exp(-(i * i) / (radius * radius * 0.5));
    \\        sum += texture(u_color, uv + vec2(texel.x * i, 0.0)) * w;
    \\        sum += texture(u_color, uv - vec2(texel.x * i, 0.0)) * w;
    \\        sum += texture(u_color, uv + vec2(0.0, texel.y * i)) * w;
    \\        sum += texture(u_color, uv - vec2(0.0, texel.y * i)) * w;
    \\        total += w * 4.0;
    \\    }
    \\    return sum / total;
    \\}
    \\
    \\void main() {
    \\    vec4 color = texture(u_color, TexCoord);
    \\    vec2 efx = texture(u_effects, TexCoord).rg;
    \\    float effects = efx.r * 255.0;
    \\    float intensity = efx.g;  // 0.0 - 1.0 (feathered edge alpha)
    \\    vec2 texel = 1.0 / u_resolution;
    \\    vec4 result = color;
    \\
    \\    // Early out — no effect flags set at this pixel
    \\    if (effects < 0.5) {
    \\        FragColor = color;
    \\        return;
    \\    }
    \\
    \\    // All effects are modulated by the intensity channel.
    \\    // CPU effect zones write feathered intensity to create soft edges.
    \\
    \\    if (hasFlag(effects, BIT_BLOOM)) {
    \\        vec4 bloomed = fastBlur(TexCoord, 6.0);
    \\        result += bloomed * intensity * 1.2;
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_GLOW)) {
    \\        vec4 glowed = fastBlur(TexCoord, 8.0);
    \\        result = mix(result, max(result, glowed * 1.5), intensity);
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_BLUR)) {
    \\        vec4 blurred = fastBlur(TexCoord, 4.0);
    \\        result = mix(result, blurred, intensity);
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_DISTORT)) {
    \\        vec2 offset = vec2(
    \\            sin(TexCoord.y * 30.0 + u_time * 3.0) * 0.008,
    \\            cos(TexCoord.x * 30.0 + u_time * 2.5) * 0.008
    \\        ) * intensity;
    \\        result = texture(u_color, TexCoord + offset);
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_HEAT)) {
    \\        float wave1 = sin(TexCoord.y * 50.0 - u_time * 5.0) * 0.008;
    \\        float wave2 = sin(TexCoord.y * 120.0 - u_time * 9.0) * 0.004;
    \\        float wave3 = cos(TexCoord.x * 30.0 + u_time * 2.0) * 0.003;
    \\        vec2 haze = vec2(wave1 + wave2 + wave3, abs(wave1) * 0.8) * intensity;
    \\        result = texture(u_color, TexCoord + haze);
    \\        result.r += 0.08 * intensity;
    \\        result.g += 0.03 * intensity;
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_CHROMATIC)) {
    \\        float strength = 3.0 * texel.x * intensity;
    \\        result.r = texture(u_color, TexCoord + vec2(strength, 0.0)).r;
    \\        result.b = texture(u_color, TexCoord - vec2(strength, 0.0)).b;
    \\        float pulse = sin(u_time * 4.0) * texel.x * intensity;
    \\        result.r = mix(result.r, texture(u_color, TexCoord + vec2(strength + pulse, pulse)).r, 0.5);
    \\        result.b = mix(result.b, texture(u_color, TexCoord - vec2(strength + pulse, pulse)).b, 0.5);
    \\    }
    \\
    \\    if (hasFlag(effects, BIT_DISSOLVE)) {
    \\        float noise = hash(floor(TexCoord * u_resolution / 3.0) + floor(u_time * 2.0));
    \\        float phase = fract(u_time * 0.4);
    \\        if (noise < phase * intensity) {
    \\            result.a = 0.0;
    \\        } else {
    \\            float edge = smoothstep(phase, phase + 0.15, noise);
    \\            result.rgb += (1.0 - edge) * vec3(1.0, 0.4, 0.1) * 1.5 * intensity;
    \\        }
    \\    }
    \\
    \\    FragColor = clamp(result, 0.0, 1.0);
    \\}
;

// Fullscreen triangle-strip quad: position (x,y) + texcoord (u,v)
// Using 2 triangles = 6 verts
const quad_vertices = [_]f32{
    // pos       // uv
    -1.0, -1.0, 0.0, 1.0, // bottom-left  (UV flipped Y: 1.0 = bottom of texture)
    1.0, -1.0, 1.0, 1.0, // bottom-right
    -1.0, 1.0, 0.0, 0.0, // top-left
    -1.0, 1.0, 0.0, 0.0, // top-left
    1.0, -1.0, 1.0, 1.0, // bottom-right
    1.0, 1.0, 1.0, 0.0, // top-right
};

pub const ShaderPipeline = struct {
    program: gl.GLuint,
    vao: gl.GLuint,
    vbo: gl.GLuint,
    color_texture: gl.GLuint,
    effect_texture: gl.GLuint,

    // Uniform locations
    u_color: gl.GLint,
    u_effects: gl.GLint,
    u_resolution: gl.GLint,
    u_time: gl.GLint,

    width: usize,
    height: usize,

    pub fn init(width: usize, height: usize) !ShaderPipeline {
        // --- Compile shaders ---
        const vert = compileShader(gl.GL_VERTEX_SHADER, vert_source) orelse return error.VertexShaderCompilationFailed;
        const frag = compileShader(gl.GL_FRAGMENT_SHADER, frag_source) orelse return error.FragmentShaderCompilationFailed;
        defer gl.deleteShader(vert);
        defer gl.deleteShader(frag);

        const program = linkProgram(vert, frag) orelse return error.ShaderLinkFailed;

        // --- Fullscreen quad VAO/VBO ---
        var vao: gl.GLuint = undefined;
        var vbo: gl.GLuint = undefined;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.genBuffers(1, @ptrCast(&vbo));

        gl.bindVertexArray(vao);
        gl.bindBuffer(gl.GL_ARRAY_BUFFER, vbo);
        gl.bufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(quad_vertices))),
            @ptrCast(&quad_vertices),
            gl.GL_STATIC_DRAW,
        );

        // Position attribute (location 0): 2 floats
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), null);

        // TexCoord attribute (location 1): 2 floats, offset by 2 floats
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));

        gl.bindVertexArray(0);

        // --- Create textures ---
        var color_tex: gl.GLuint = undefined;
        var effect_tex: gl.GLuint = undefined;
        gl.genTextures(1, @ptrCast(&color_tex));
        gl.genTextures(1, @ptrCast(&effect_tex));

        // Color texture (RGBA8)
        gl.bindTexture(gl.GL_TEXTURE_2D, color_tex);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.texImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_RGBA8,
            @intCast(width),
            @intCast(height),
            0,
            gl.GL_RGBA,
            gl.GL_UNSIGNED_BYTE,
            null,
        );

        // Effect texture (RG8 — two channels: R=flags, G=intensity)
        gl.bindTexture(gl.GL_TEXTURE_2D, effect_tex);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.pixelStorei(gl.GL_UNPACK_ALIGNMENT, 2);
        gl.texImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_RG8,
            @intCast(width),
            @intCast(height),
            0,
            gl.GL_RG,
            gl.GL_UNSIGNED_BYTE,
            null,
        );

        // --- Get uniform locations ---
        const u_color = gl.getUniformLocation(program, "u_color");
        const u_effects = gl.getUniformLocation(program, "u_effects");
        const u_resolution = gl.getUniformLocation(program, "u_resolution");
        const u_time = gl.getUniformLocation(program, "u_time");

        return ShaderPipeline{
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .color_texture = color_tex,
            .effect_texture = effect_tex,
            .u_color = u_color,
            .u_effects = u_effects,
            .u_resolution = u_resolution,
            .u_time = u_time,
            .width = width,
            .height = height,
        };
    }

    /// Upload CPU buffers to GPU textures and draw the fullscreen quad
    pub fn render(self: *const ShaderPipeline, pixel_buffer: []const u32, effect_buffer: []const u16, time: f32) void {
        // Upload color buffer (ABGR u32 → [R,G,B,A] in LE memory → matches GL_RGBA)
        gl.activeTexture(gl.GL_TEXTURE0);
        gl.bindTexture(gl.GL_TEXTURE_2D, self.color_texture);
        gl.texSubImage2D(
            gl.GL_TEXTURE_2D,
            0,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            gl.GL_RGBA,
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(pixel_buffer.ptr),
        );

        // Upload effect buffer (u16 per pixel → LE memory = [flags, intensity] → GL_RG)
        gl.activeTexture(gl.GL_TEXTURE1);
        gl.bindTexture(gl.GL_TEXTURE_2D, self.effect_texture);
        gl.pixelStorei(gl.GL_UNPACK_ALIGNMENT, 2);
        gl.texSubImage2D(
            gl.GL_TEXTURE_2D,
            0,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            gl.GL_RG,
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(effect_buffer.ptr),
        );

        // Draw
        gl.clearColor(0.0, 0.0, 0.0, 1.0);
        gl.clear(gl.GL_COLOR_BUFFER_BIT);

        gl.useProgram(self.program);

        // Set uniforms
        gl.uniform1i(self.u_color, 0); // texture unit 0
        gl.uniform1i(self.u_effects, 1); // texture unit 1
        gl.uniform2f(self.u_resolution, @floatFromInt(self.width), @floatFromInt(self.height));
        gl.uniform1f(self.u_time, time);

        // Draw fullscreen quad
        gl.bindVertexArray(self.vao);
        gl.drawArrays(gl.GL_TRIANGLES, 0, 6);
        gl.bindVertexArray(0);
    }

    pub fn deinit(self: *ShaderPipeline) void {
        const color_tex = self.color_texture;
        const effect_tex = self.effect_texture;
        gl.deleteTextures(1, @ptrCast(&color_tex));
        gl.deleteTextures(1, @ptrCast(&effect_tex));
        const vbo = self.vbo;
        gl.deleteBuffers(1, @ptrCast(&vbo));
        const vao = self.vao;
        gl.deleteVertexArrays(1, @ptrCast(&vao));
        gl.deleteProgram(self.program);
    }
};

// --- Shader compilation helpers ---

fn compileShader(shader_type: gl.GLenum, source: [:0]const u8) ?gl.GLuint {
    const shader = gl.createShader(shader_type);
    const src_ptr: [*]const gl.GLchar = source.ptr;
    gl.shaderSource(shader, 1, @ptrCast(&src_ptr), null);
    gl.compileShader(shader);

    var success: gl.GLint = 0;
    gl.getShaderiv(shader, gl.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var log_len: gl.GLint = 0;
        gl.getShaderiv(shader, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            gl.getShaderInfoLog(shader, 1024, null, &buf);
            const msg: []const u8 = buf[0..@min(@as(usize, @intCast(log_len)), 1024)];
            std.log.err("Shader compile error: {s}", .{msg});
        }
        gl.deleteShader(shader);
        return null;
    }
    return shader;
}

fn linkProgram(vert: gl.GLuint, frag: gl.GLuint) ?gl.GLuint {
    const program = gl.createProgram();
    gl.attachShader(program, vert);
    gl.attachShader(program, frag);
    gl.linkProgram(program);

    var success: gl.GLint = 0;
    gl.getProgramiv(program, gl.GL_LINK_STATUS, &success);
    if (success == 0) {
        var log_len: gl.GLint = 0;
        gl.getProgramiv(program, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            gl.getProgramInfoLog(program, 1024, null, &buf);
            const msg: []const u8 = buf[0..@min(@as(usize, @intCast(log_len)), 1024)];
            std.log.err("Program link error: {s}", .{msg});
        }
        gl.deleteProgram(program);
        return null;
    }
    return program;
}
