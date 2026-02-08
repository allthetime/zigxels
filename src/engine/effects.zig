/// Effect bitflags — packed into a single u8 per pixel.
/// Each bit marks a post-processing effect the GPU shader should apply.
///
/// Usage:
///   const fx = Effect{ .bloom = true, .glow = true };
///   drawRect(engine, x, y, w, h, color, fx);
///
pub const Effect = packed struct(u8) {
    bloom: bool = false, // bit 0 — bright additive glow (explosions, muzzle flash)
    blur: bool = false, // bit 1 — gaussian blur (fluids, smoke)
    distort: bool = false, // bit 2 — UV distortion (heat shimmer, shockwaves)
    glow: bool = false, // bit 3 — soft edge glow (tail segments, energy)
    heat: bool = false, // bit 4 — heat haze (rising thermal distortion)
    chromatic: bool = false, // bit 5 — chromatic aberration (RGB channel split)
    dissolve: bool = false, // bit 6 — pixel dissolve (noisy fade-out)
    _padding: u1 = 0, // bit 7 reserved

    pub const none = Effect{};
    pub const bloom_only = Effect{ .bloom = true };
    pub const blur_only = Effect{ .blur = true };
    pub const glow_only = Effect{ .glow = true };
    pub const distort_only = Effect{ .distort = true };
    pub const heat_only = Effect{ .heat = true };
    pub const chromatic_only = Effect{ .chromatic = true };
    pub const dissolve_only = Effect{ .dissolve = true };

    pub fn toByte(self: Effect) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Effect {
        return @bitCast(byte);
    }

    pub fn merge(a: Effect, b: Effect) Effect {
        return @bitCast(a.toByte() | b.toByte());
    }

    pub fn hasAny(self: Effect) bool {
        return self.toByte() != 0;
    }

    /// Pack effect flags + intensity into a u16 for the effect buffer.
    /// Low byte = effect flags, high byte = intensity (0-255).
    pub fn withIntensity(self: Effect, intensity: u8) u16 {
        return @as(u16, intensity) << 8 | @as(u16, self.toByte());
    }

    /// Full-strength packed value (intensity = 255)
    pub fn toU16(self: Effect) u16 {
        return self.withIntensity(255);
    }

    /// Extract effect flags from a packed u16
    pub fn flagsFromU16(val: u16) Effect {
        return @bitCast(@as(u8, @truncate(val)));
    }

    /// Extract intensity (0-255) from a packed u16
    pub fn intensityFromU16(val: u16) u8 {
        return @truncate(val >> 8);
    }
};
