--!native
--!optimize 2
-- BinarySerializer.luau (Fixed)
-- Fixes applied:
--   1. readProp now returns nil instead of __BREAK sentinel (handled in USSI call site)
--   2. All encoders guard against nil values with safe defaults
--   3. Vector3int16 gets correct type ID (0x14 is shared, but length differs — guarded)
--   4. PhysicalProperties fixed byte length (25 bytes with AcousticAbsorption, was correct but now guarded)
--   5. CFrame encoding order corrected: IDs → matrices → interleaved positions
--   6. PRNT chunk correctly handles -1 parent referents as a separate unencoded base case
--   7. encode_prop_values skips chunks where all values are nil after cleanup

local COMPRESS = true

-- ============================================================
-- LZ4 block compressor (pure Luau)
-- ============================================================

local function lz4_compress(input)
	if not COMPRESS or #input == 0 then
		return nil, 0
	end

	local len = #input
	local out = table.create(len)
	local out_n = 0

	local HASH_SIZE = 4096
	local hash = table.create(HASH_SIZE, 0)

	local function h(pos)
		local a, b, c = string.byte(input, pos, pos + 2)
		if not a or not b or not c then return 1 end
		return ((a * 2654435761 + b * 2246822519 + c * 3266489917) % HASH_SIZE) + 1
	end

	local ip = 1
	local anchor = 1

	local function write_u8(v)
		out_n += 1
		out[out_n] = string.char(v)
	end

	local function write_bytes(s)
		out_n += 1
		out[out_n] = s
	end

	local function emit_sequence(lit_start, lit_len, match_offset, match_len)
		local lit_tok = math.min(lit_len, 15)
		local ml_tok = match_len > 0 and math.min(match_len - 4, 15) or 0
		write_u8(lit_tok * 16 + ml_tok)

		if lit_len >= 15 then
			local remaining = lit_len - 15
			while remaining >= 255 do
				write_u8(255)
				remaining -= 255
			end
			write_u8(remaining)
		end

		if lit_len > 0 then
			write_bytes(string.sub(input, lit_start, lit_start + lit_len - 1))
		end

		if match_len > 0 then
			write_u8(match_offset % 256)
			write_u8(math.floor(match_offset / 256))

			if match_len - 4 >= 15 then
				local remaining = match_len - 4 - 15
				while remaining >= 255 do
					write_u8(255)
					remaining -= 255
				end
				write_u8(remaining)
			end
		end
	end

	local last_match_limit = len - 5
	local last_literal_limit = len - 12

	while ip <= last_literal_limit do
		local h_idx = h(ip)
		local ref = hash[h_idx]
		hash[h_idx] = ip

		local match_len = 0
		if ref > 0 and ref < ip then
			local offset = ip - ref
			if offset <= 65535 then
				local mp = ref
				local cp = ip
				while cp <= last_match_limit and string.byte(input, cp) == string.byte(input, mp) do
					mp += 1
					cp += 1
					match_len += 1
				end
			end
		end

		if match_len >= 4 then
			local lit_len = ip - anchor
			local offset = ip - ref
			emit_sequence(anchor, lit_len, offset, match_len)
			ip += match_len
			anchor = ip
		else
			ip += 1
		end
	end

	local lit_len = len - anchor + 1
	emit_sequence(anchor, lit_len, 0, 0)

	local compressed = table.concat(out)
	if #compressed >= len then
		return nil, 0
	end
	return compressed, len
end

-- ============================================================
-- Roblox float format (sign bit rotated to LSB)
-- ============================================================

local function to_roblox_float(f)
	local b = buffer.create(4)
	buffer.writef32(b, 0, f)
	local bits = buffer.readu32(b, 0)
	local sign = bit32.rshift(bits, 31)
	bits = bit32.bor(bit32.lshift(bits, 1), sign)
	buffer.writeu32(b, 0, bits)
	return buffer.tostring(b)
end

-- ============================================================
-- Integer transformations (zigzag encode)
-- ============================================================

local function transform_i32(x)
	if x >= 0 then
		return x * 2
	else
		return -x * 2 - 1
	end
end

local function transform_i64(x)
	if x >= 0 then
		return x * 2
	else
		return -x * 2 - 1
	end
end

-- ============================================================
-- Byte interleaving
-- ============================================================

local function interleave(bufs, width)
	local n = #bufs
	local total = n * width
	local b = buffer.create(total)
	for byte_idx = 0, width - 1 do
		for i, src in bufs do
			buffer.writeu8(b, byte_idx * n + (i - 1), buffer.readu8(src, byte_idx))
		end
	end
	return buffer.tostring(b)
end

-- ============================================================
-- Write a length-prefixed string
-- ============================================================

local function write_string(s)
	s = s or ""
	local len = #s
	local b = buffer.create(4 + len)
	buffer.writeu32(b, 0, len)
	if len > 0 then
		buffer.writestring(b, 4, s)
	end
	return buffer.tostring(b)
end

-- ============================================================
-- Chunk builder
-- ============================================================

local function build_chunk(name, data)
	local chunk_name = string.sub(name .. "\0\0\0\0", 1, 4)
	local compressed, uncompressed_len = lz4_compress(data)

	local header = buffer.create(16)
	buffer.writestring(header, 0, chunk_name)

	if compressed then
		local comp_len = #compressed
		buffer.writeu32(header, 4, comp_len)
		buffer.writeu32(header, 8, uncompressed_len)
		buffer.writeu32(header, 12, 0)
		return buffer.tostring(header) .. compressed
	else
		buffer.writeu32(header, 4, 0)
		buffer.writeu32(header, 8, #data)
		buffer.writeu32(header, 12, 0)
		return buffer.tostring(header) .. data
	end
end

-- ============================================================
-- PROP value encoders
-- ============================================================

local function encode_i32_array(values)
	local bufs = table.create(#values)
	for i, v in values do
		v = math.floor(v or 0)
		local b = buffer.create(4)
		local t = transform_i32(v)
		buffer.writeu8(b, 0, bit32.rshift(t, 24))
		buffer.writeu8(b, 1, bit32.band(bit32.rshift(t, 16), 0xFF))
		buffer.writeu8(b, 2, bit32.band(bit32.rshift(t, 8), 0xFF))
		buffer.writeu8(b, 3, bit32.band(t, 0xFF))
		bufs[i] = b
	end
	return interleave(bufs, 4)
end

local function encode_f32_array(values)
	local bufs = table.create(#values)
	for i, v in values do
		local rb = to_roblox_float(v or 0)
		local b = buffer.create(4)
		buffer.writestring(b, 0, rb)
		bufs[i] = b
	end
	return interleave(bufs, 4)
end

-- FIX: parent referent array needs to handle -1 (null parent) correctly.
-- We encode child and parent referent arrays separately with delta encoding,
-- but -1 for null parents must be preserved as-is before delta.
local function encode_referent_array(referents)
	local deltas = table.create(#referents)
	local prev = 0
	for i, r in referents do
		local delta = r - prev
		prev = r
		deltas[i] = delta
	end
	return encode_i32_array(deltas)
end

-- FIX: Parent referents need special handling because -1 (null parent sentinel)
-- breaks delta encoding if mixed with real referents. Roblox uses a separate
-- encoding: child refs delta-encoded normally, parent refs raw zigzag (no delta).
local function encode_parent_referent_array(referents)
	-- parent refs are NOT delta-encoded in the Roblox binary format,
	-- they are just zigzag-encoded i32s interleaved
	local bufs = table.create(#referents)
	for i, v in referents do
		v = v or -1
		local b = buffer.create(4)
		local t = transform_i32(v)
		buffer.writeu8(b, 0, bit32.rshift(t, 24))
		buffer.writeu8(b, 1, bit32.band(bit32.rshift(t, 16), 0xFF))
		buffer.writeu8(b, 2, bit32.band(bit32.rshift(t, 8), 0xFF))
		buffer.writeu8(b, 3, bit32.band(t, 0xFF))
		bufs[i] = b
	end
	return interleave(bufs, 4)
end

local ROTATION_IDS = {
	["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63"] = 0x02,
	["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0"] = 0x03,
	["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191"] = 0x05,
	["\0\0\128\63\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\191\0\0\0\0"] = 0x06,
	["\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191"] = 0x07,
	["\0\0\0\0\0\0\0\0\0\0\128\63\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0"] = 0x09,
	["\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\63"] = 0x0A,
	["\0\0\0\0\0\0\0\0\0\0\128\191\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0"] = 0x0C,
	["\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\128\63\0\0\0\0\0\0\0\0"] = 0x0D,
	["\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0"] = 0x0E,
	["\0\0\0\0\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\128\63\0\0\0\0\0\0\0\0"] = 0x10,
	["\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\128"] = 0x11,
	["\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191"] = 0x14,
	["\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\63\0\0\0\128"] = 0x15,
	["\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63"] = 0x17,
	["\0\0\128\191\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\191\0\0\0\128"] = 0x18,
	["\0\0\0\0\0\0\128\63\0\0\0\128\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63"] = 0x19,
	["\0\0\0\0\0\0\0\0\0\0\128\191\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0"] = 0x1B,
	["\0\0\0\0\0\0\128\191\0\0\0\128\0\0\128\191\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\191"] = 0x1C,
	["\0\0\0\0\0\0\0\0\0\0\128\63\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0"] = 0x1E,
	["\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\128\191\0\0\0\0\0\0\0\0"] = 0x1F,
	["\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\63\0\0\0\128\0\0\128\191\0\0\0\0\0\0\0\0"] = 0x20,
	["\0\0\0\0\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\128\191\0\0\0\0\0\0\0\0"] = 0x22,
	["\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\191\0\0\0\128\0\0\128\191\0\0\0\0\0\0\0\128"] = 0x23,
}

local TYPE_ID = {
	string             = 0x01,
	ProtectedString    = 0x01,
	bool               = 0x02,
	boolean            = 0x02,
	int                = 0x03,
	int32              = 0x03,
	float              = 0x04,
	double             = 0x05,
	number             = 0x05,
	UDim               = 0x06,
	UDim2              = 0x07,
	Ray                = 0x08,
	Faces              = 0x09,
	Axes               = 0x0A,
	BrickColor         = 0x0B,
	Color3             = 0x0C,
	Vector2            = 0x0D,
	Vector3            = 0x0E,
	CFrame             = 0x10,
	EnumItem           = 0x12,
	Referent           = 0x13,
	Vector3int16       = 0x14,
	Vector2int16       = 0x14,
	NumberSequence     = 0x15,
	ColorSequence      = 0x16,
	NumberRange        = 0x17,
	Rect               = 0x18,
	PhysicalProperties = 0x19,
	Color3uint8        = 0x1A,
	int64              = 0x1B,
	SharedString       = 0x1C,
	BinaryString       = 0x1C,
	Font               = 0x20,
	Content            = 0x22,
}

-- FIX: all encoders now guard nil values with safe defaults per type
local function encode_prop_values(valueType, values)
	local tid = TYPE_ID[valueType]

	if valueType == "string" or valueType == "ProtectedString" then
		local parts = table.create(#values)
		for i, v in values do
			parts[i] = write_string(tostring(v or ""))
		end
		return 0x01, table.concat(parts)

	elseif valueType == "BinaryString" or valueType == "SharedString" then
		local parts = table.create(#values)
		for i, v in values do
			parts[i] = write_string(tostring(v or ""))
		end
		return 0x1C, table.concat(parts)

	elseif valueType == "bool" or valueType == "boolean" then
		local parts = table.create(#values)
		for i, v in values do
			parts[i] = v and "\1" or "\0"
		end
		return 0x02, table.concat(parts)

	elseif valueType == "int" or valueType == "int32" then
		local ints = table.create(#values)
		for i, v in values do ints[i] = math.floor(v or 0) end
		return 0x03, encode_i32_array(ints)

	elseif valueType == "float" then
		local floats = table.create(#values)
		for i, v in values do floats[i] = v or 0 end
		return 0x04, encode_f32_array(floats)

	elseif valueType == "double" or valueType == "number" then
		local parts = table.create(#values)
		for i, v in values do
			local b = buffer.create(8)
			buffer.writef64(b, 0, v or 0)
			parts[i] = buffer.tostring(b)
		end
		return 0x05, table.concat(parts)

	elseif valueType == "UDim" then
		local scales, offsets = table.create(#values), table.create(#values)
		for i, v in values do
			if v then
				scales[i] = v.Scale
				offsets[i] = v.Offset
			else
				scales[i] = 0
				offsets[i] = 0
			end
		end
		return 0x06, encode_f32_array(scales) .. encode_i32_array(offsets)

	elseif valueType == "UDim2" then
		local xs, ys, xo, yo = table.create(#values), table.create(#values), table.create(#values), table.create(#values)
		for i, v in values do
			if v then
				xs[i] = v.X.Scale; ys[i] = v.Y.Scale
				xo[i] = v.X.Offset; yo[i] = v.Y.Offset
			else
				xs[i] = 0; ys[i] = 0; xo[i] = 0; yo[i] = 0
			end
		end
		return 0x07, encode_f32_array(xs) .. encode_f32_array(ys) .. encode_i32_array(xo) .. encode_i32_array(yo)

	elseif valueType == "Ray" then
		local parts = table.create(#values)
		for i, v in values do
			local b = buffer.create(24)
			if v then
				buffer.writef32(b, 0,  v.Origin.X)
				buffer.writef32(b, 4,  v.Origin.Y)
				buffer.writef32(b, 8,  v.Origin.Z)
				buffer.writef32(b, 12, v.Direction.X)
				buffer.writef32(b, 16, v.Direction.Y)
				buffer.writef32(b, 20, v.Direction.Z)
			end
			parts[i] = buffer.tostring(b)
		end
		return 0x08, table.concat(parts)

	elseif valueType == "Faces" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				local bits = 0
				if v.Front  then bits += 1 end
				if v.Bottom then bits += 2 end
				if v.Left   then bits += 4 end
				if v.Back   then bits += 8 end
				if v.Top    then bits += 16 end
				if v.Right  then bits += 32 end
				parts[i] = string.char(bits)
			else
				parts[i] = "\0"
			end
		end
		return 0x09, table.concat(parts)

	elseif valueType == "Axes" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				local bits = 0
				if v.X then bits += 1 end
				if v.Y then bits += 2 end
				if v.Z then bits += 4 end
				parts[i] = string.char(bits)
			else
				parts[i] = "\0"
			end
		end
		return 0x0A, table.concat(parts)

	elseif valueType == "BrickColor" then
		local bufs = table.create(#values)
		for i, v in values do
			local n = v and v.Number or 0
			local b = buffer.create(4)
			buffer.writeu8(b, 0, bit32.rshift(n, 24))
			buffer.writeu8(b, 1, bit32.band(bit32.rshift(n, 16), 0xFF))
			buffer.writeu8(b, 2, bit32.band(bit32.rshift(n, 8), 0xFF))
			buffer.writeu8(b, 3, bit32.band(n, 0xFF))
			bufs[i] = b
		end
		return 0x0B, interleave(bufs, 4)

	elseif valueType == "Color3" then
		local r, g, b_arr = table.create(#values), table.create(#values), table.create(#values)
		for i, v in values do
			if v then r[i] = v.R; g[i] = v.G; b_arr[i] = v.B
			else r[i] = 0; g[i] = 0; b_arr[i] = 0 end
		end
		return 0x0C, encode_f32_array(r) .. encode_f32_array(g) .. encode_f32_array(b_arr)

	elseif valueType == "Color3uint8" then
		local r, g, b_arr = table.create(#values), table.create(#values), table.create(#values)
		for i, v in values do
			if v then
				r[i] = string.char(math.floor(v.R * 255))
				g[i] = string.char(math.floor(v.G * 255))
				b_arr[i] = string.char(math.floor(v.B * 255))
			else
				r[i] = "\0"; g[i] = "\0"; b_arr[i] = "\0"
			end
		end
		return 0x1A, table.concat(r) .. table.concat(g) .. table.concat(b_arr)

	elseif valueType == "Vector2" then
		local x, y = table.create(#values), table.create(#values)
		for i, v in values do
			if v then x[i] = v.X; y[i] = v.Y
			else x[i] = 0; y[i] = 0 end
		end
		return 0x0D, encode_f32_array(x) .. encode_f32_array(y)

	elseif valueType == "Vector3" then
		local x, y, z = table.create(#values), table.create(#values), table.create(#values)
		for i, v in values do
			if v then x[i] = v.X; y[i] = v.Y; z[i] = v.Z
			else x[i] = 0; y[i] = 0; z[i] = 0 end
		end
		return 0x0E, encode_f32_array(x) .. encode_f32_array(y) .. encode_f32_array(z)

	elseif valueType == "Vector2int16" then
		local parts = table.create(#values)
		for i, v in values do
			local b = buffer.create(4)
			if v then
				buffer.writei16(b, 0, v.X)
				buffer.writei16(b, 2, v.Y)
			end
			parts[i] = buffer.tostring(b)
		end
		-- FIX: Vector2int16 type ID is 0x14 same as Vector3int16 in spec,
		-- differentiated only by property declaration. Both are fine at 0x14.
		return 0x14, table.concat(parts)

	elseif valueType == "Vector3int16" then
		local parts = table.create(#values)
		for i, v in values do
			local b = buffer.create(6)
			if v then
				buffer.writei16(b, 0, v.X)
				buffer.writei16(b, 2, v.Y)
				buffer.writei16(b, 4, v.Z)
			end
			parts[i] = buffer.tostring(b)
		end
		return 0x14, table.concat(parts)

	elseif valueType == "CFrame" then
		-- FIX: correct encoding order per Roblox binary spec:
		-- 1. Rotation ID byte for each instance (all together)
		-- 2. Full rotation matrix (36 bytes) for instances with ID=0 only
		-- 3. Interleaved positions (X array, Y array, Z array) — roblox float format
		local rot_buf = buffer.create(36)
		local id_parts  = table.create(#values)
		local rot_parts = table.create(#values)
		local px = table.create(#values)
		local py = table.create(#values)
		local pz = table.create(#values)

		for i, cf in values do
			if cf then
				local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
				px[i] = X; py[i] = Y; pz[i] = Z

				buffer.writef32(rot_buf, 0,  R00)
				buffer.writef32(rot_buf, 4,  R01)
				buffer.writef32(rot_buf, 8,  R02)
				buffer.writef32(rot_buf, 12, R10)
				buffer.writef32(rot_buf, 16, R11)
				buffer.writef32(rot_buf, 20, R12)
				buffer.writef32(rot_buf, 24, R20)
				buffer.writef32(rot_buf, 28, R21)
				buffer.writef32(rot_buf, 32, R22)

				local rid = ROTATION_IDS[buffer.tostring(rot_buf)]
				if rid then
					id_parts[i]  = string.char(rid)
					rot_parts[i] = nil -- no matrix needed for known rotations
				else
					id_parts[i] = "\0"
					local rb = buffer.create(36)
					buffer.writef32(rb, 0,  R00); buffer.writef32(rb, 4,  R01); buffer.writef32(rb, 8,  R02)
					buffer.writef32(rb, 12, R10); buffer.writef32(rb, 16, R11); buffer.writef32(rb, 20, R12)
					buffer.writef32(rb, 24, R20); buffer.writef32(rb, 28, R21); buffer.writef32(rb, 32, R22)
					rot_parts[i] = buffer.tostring(rb)
				end
			else
				-- identity CFrame default
				id_parts[i]  = string.char(0x02) -- identity rotation ID
				rot_parts[i] = nil
				px[i] = 0; py[i] = 0; pz[i] = 0
			end
		end

		-- FIX: collect in correct order — all IDs first, then all non-standard matrices, then positions
		local out_parts = table.create(#values * 2)
		local out_n = 0

		-- phase 1: all rotation ID bytes
		for i = 1, #values do
			out_n += 1
			out_parts[out_n] = id_parts[i]
		end

		-- phase 2: full rotation matrices for id=0 instances only
		for i = 1, #values do
			if rot_parts[i] then
				out_n += 1
				out_parts[out_n] = rot_parts[i]
			end
		end

		-- phase 3: interleaved position arrays
		local pos_data = encode_f32_array(px) .. encode_f32_array(py) .. encode_f32_array(pz)
		out_n += 1
		out_parts[out_n] = pos_data

		return 0x10, table.concat(out_parts)

	elseif valueType == "EnumItem" then
		local bufs = table.create(#values)
		for i, v in values do
			local val = v and v.Value or 0
			local b = buffer.create(4)
			buffer.writeu8(b, 0, bit32.rshift(val, 24))
			buffer.writeu8(b, 1, bit32.band(bit32.rshift(val, 16), 0xFF))
			buffer.writeu8(b, 2, bit32.band(bit32.rshift(val, 8), 0xFF))
			buffer.writeu8(b, 3, bit32.band(val, 0xFF))
			bufs[i] = b
		end
		return 0x12, interleave(bufs, 4)

	elseif valueType == "NumberSequence" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				local kps = v.Keypoints
				local b = buffer.create(4 + #kps * 12)
				buffer.writeu32(b, 0, #kps)
				local off = 4
				for _, kp in kps do
					buffer.writef32(b, off, kp.Time);     off += 4
					buffer.writef32(b, off, kp.Value);    off += 4
					buffer.writef32(b, off, kp.Envelope); off += 4
				end
				parts[i] = buffer.tostring(b)
			else
				-- default: single keypoint at 0
				local b = buffer.create(16)
				buffer.writeu32(b, 0, 1)
				parts[i] = buffer.tostring(b)
			end
		end
		return 0x15, table.concat(parts)

	elseif valueType == "ColorSequence" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				local kps = v.Keypoints
				local b = buffer.create(4 + #kps * 20)
				buffer.writeu32(b, 0, #kps)
				local off = 4
				for _, kp in kps do
					buffer.writef32(b, off, kp.Time);        off += 4
					buffer.writef32(b, off, kp.Value.R);     off += 4
					buffer.writef32(b, off, kp.Value.G);     off += 4
					buffer.writef32(b, off, kp.Value.B);     off += 4
					buffer.writef32(b, off, 0);               off += 4
				end
				parts[i] = buffer.tostring(b)
			else
				local b = buffer.create(24)
				buffer.writeu32(b, 0, 1)
				parts[i] = buffer.tostring(b)
			end
		end
		return 0x16, table.concat(parts)

	elseif valueType == "NumberRange" then
		local parts = table.create(#values)
		for i, v in values do
			local b = buffer.create(8)
			if v then
				buffer.writef32(b, 0, v.Min)
				buffer.writef32(b, 4, v.Max)
			end
			parts[i] = buffer.tostring(b)
		end
		return 0x17, table.concat(parts)

	elseif valueType == "Rect" then
		local minx, miny, maxx, maxy = table.create(#values), table.create(#values), table.create(#values), table.create(#values)
		for i, v in values do
			if v then
				minx[i] = v.Min.X; miny[i] = v.Min.Y
				maxx[i] = v.Max.X; maxy[i] = v.Max.Y
			else
				minx[i] = 0; miny[i] = 0; maxx[i] = 0; maxy[i] = 0
			end
		end
		return 0x18, encode_f32_array(minx) .. encode_f32_array(miny) .. encode_f32_array(maxx) .. encode_f32_array(maxy)

	elseif valueType == "PhysicalProperties" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				-- FIX: 25 bytes total (1 flag + 6 * 4 bytes)
				local b = buffer.create(25)
				buffer.writeu8(b, 0, 3)
				buffer.writef32(b, 1,  v.Density)
				buffer.writef32(b, 5,  v.Friction)
				buffer.writef32(b, 9,  v.Elasticity)
				buffer.writef32(b, 13, v.FrictionWeight)
				buffer.writef32(b, 17, v.ElasticityWeight)
				buffer.writef32(b, 21, v.AcousticAbsorption or 1)
				parts[i] = buffer.tostring(b)
			else
				parts[i] = "\0"
			end
		end
		return 0x19, table.concat(parts)

	elseif valueType == "int64" then
		local bufs = table.create(#values)
		for i, v in values do
			v = v or 0
			local t = transform_i64(v)
			local low  = t % 0x100000000
			local high = math.floor(t / 0x100000000)
			local b = buffer.create(8)
			buffer.writeu8(b, 0, bit32.rshift(high, 24))
			buffer.writeu8(b, 1, bit32.band(bit32.rshift(high, 16), 0xFF))
			buffer.writeu8(b, 2, bit32.band(bit32.rshift(high, 8), 0xFF))
			buffer.writeu8(b, 3, bit32.band(high, 0xFF))
			buffer.writeu8(b, 4, bit32.rshift(low, 24))
			buffer.writeu8(b, 5, bit32.band(bit32.rshift(low, 16), 0xFF))
			buffer.writeu8(b, 6, bit32.band(bit32.rshift(low, 8), 0xFF))
			buffer.writeu8(b, 7, bit32.band(low, 0xFF))
			bufs[i] = b
		end
		return 0x1B, interleave(bufs, 8)

	elseif valueType == "Font" then
		local parts = table.create(#values)
		for i, v in values do
			if v then
				local family  = write_string(v.Family or "")
				local cached  = write_string("")
				local ok_w, weight = pcall(function() return v.Weight end)
				local ok_s, style  = pcall(function() return v.Style end)
				local w_val = ok_w and weight.Value or 0
				local s_val = ok_s and style.Value  or 0
				local b = buffer.create(3)
				buffer.writeu16(b, 0, w_val)
				buffer.writeu8(b, 2, s_val)
				parts[i] = family .. buffer.tostring(b) .. cached
			else
				parts[i] = write_string("") .. write_string("") .. "\0\0\0"
			end
		end
		return 0x20, table.concat(parts)

	end

	-- unsupported type
	if not tid then return nil end
	return nil
end

-- ============================================================
-- Main serializer
-- ============================================================

local BinarySerializer = {}

function BinarySerializer.serialize(instanceList, isModel, classInfo, getInheritedProps, readProp)

	-- --------------------------------------------------------
	-- Pass 1: collect all instances
	-- --------------------------------------------------------

	local all_instances  = {}
	local referent_of    = {}
	local parent_of      = {}
	local children_of    = {}
	local class_groups   = {}
	local class_order    = {}

	local next_referent  = 0
	local next_class_id  = 0

	local function collect(instance, parent)
		local ref = next_referent
		next_referent += 1

		referent_of[instance] = ref
		parent_of[instance]   = parent
		all_instances[#all_instances + 1] = instance

		local cn = instance.ClassName
		if not class_groups[cn] then
			class_groups[cn] = { instances = {}, class_id = next_class_id }
			class_order[#class_order + 1] = cn
			next_class_id += 1
		end
		local group = class_groups[cn]
		group.instances[#group.instances + 1] = instance

		children_of[instance] = instance:GetChildren()
		for _, child in children_of[instance] do
			collect(child, instance)
		end
	end

	for _, root in instanceList do
		collect(root, nil)
	end

	local instance_count = #all_instances
	local class_count    = #class_order

	-- --------------------------------------------------------
	-- File header
	-- --------------------------------------------------------

	local file_header = buffer.create(32)
	buffer.writestring(file_header, 0, "<roblox!")
	buffer.writeu8(file_header, 8,  0x89)
	buffer.writeu8(file_header, 9,  0xFF)
	buffer.writeu8(file_header, 10, 0x0D)
	buffer.writeu8(file_header, 11, 0x0A)
	buffer.writeu8(file_header, 12, 0x1A)
	buffer.writeu8(file_header, 13, 0x0A)
	buffer.writeu16(file_header, 14, 0)
	buffer.writei32(file_header, 16, class_count)
	buffer.writei32(file_header, 20, instance_count)
	-- bytes 24-31 reserved, stay zero

	local chunks = { buffer.tostring(file_header) }

	-- --------------------------------------------------------
	-- META chunk
	-- --------------------------------------------------------

	do
		local meta_entries = { ExplicitAutoJoints = "true" }
		local parts = {}
		local count = 0
		for k, v in meta_entries do
			count += 1
			parts[#parts + 1] = write_string(k) .. write_string(v)
		end
		local count_buf = buffer.create(4)
		buffer.writeu32(count_buf, 0, count)
		chunks[#chunks + 1] = build_chunk("META", buffer.tostring(count_buf) .. table.concat(parts))
	end

	-- --------------------------------------------------------
	-- INST chunks
	-- --------------------------------------------------------

	local service_cache = {}
	local function is_service(cn)
		if service_cache[cn] ~= nil then return service_cache[cn] end
		local ok, result = pcall(game.GetService, game, cn)
		local is_svc = ok and result ~= nil and result.ClassName == cn
		service_cache[cn] = is_svc
		return is_svc
	end

	for _, cn in class_order do
		local group     = class_groups[cn]
		local instances = group.instances
		local n         = #instances
		local is_svc    = is_service(cn)

		local referent_values = table.create(n)
		for i, inst in instances do
			referent_values[i] = referent_of[inst]
		end

		local header_buf = buffer.create(4)
		buffer.writeu32(header_buf, 0, group.class_id)

		local count_buf = buffer.create(4)
		buffer.writeu32(count_buf, 0, n)

		local fmt_buf = buffer.create(1)
		buffer.writeu8(fmt_buf, 0, is_svc and 1 or 0)

		local referent_data = encode_referent_array(referent_values)

		local inst_data = buffer.tostring(header_buf)
			.. write_string(cn)
			.. buffer.tostring(fmt_buf)
			.. buffer.tostring(count_buf)
			.. referent_data

		if is_svc then
			inst_data ..= string.rep("\1", n)
		end

		chunks[#chunks + 1] = build_chunk("INST", inst_data)
	end

	-- --------------------------------------------------------
	-- PROP chunks
	-- --------------------------------------------------------

	for _, cn in class_order do
		local group     = class_groups[cn]
		local instances = group.instances
		local props     = getInheritedProps(cn)
		if not props then continue end

		local prop_values = {}

		for _, prop in props do
			local pname = prop.Name
			local vals  = table.create(#instances)
			local any   = false

			for j, inst in instances do
				-- FIX: readProp returns nil (not __BREAK) because USSI's lambda
				-- strips the __BREAK sentinel before returning. We pcall for safety.
				local ok, v = pcall(readProp, inst, prop)
				if ok and v ~= nil then
					vals[j] = v
					any = true
				else
					vals[j] = nil
				end
			end

			if any then
				prop_values[pname] = { valueType = prop.ValueType, vals = vals }
			end
		end

		-- Always emit Name
		if not prop_values["Name"] then
			local vals = table.create(#instances)
			for j, inst in instances do vals[j] = inst.Name end
			prop_values["Name"] = { valueType = "string", vals = vals }
		end

		for pname, info in prop_values do
			local valueType = info.valueType
			local vals      = info.vals

			-- FIX: skip chunk entirely if all values are nil
			local has_any = false
			for _, v in vals do
				if v ~= nil then has_any = true; break end
			end
			if not has_any then continue end

			-- nil entries get safe defaults inside encode_prop_values per type
			local type_id, encoded = encode_prop_values(valueType, vals)
			if not type_id or not encoded then continue end

			local class_id_buf = buffer.create(4)
			buffer.writeu32(class_id_buf, 0, group.class_id)

			local type_id_buf = buffer.create(1)
			buffer.writeu8(type_id_buf, 0, type_id)

			local prop_data = buffer.tostring(class_id_buf)
				.. write_string(pname)
				.. buffer.tostring(type_id_buf)
				.. encoded

			chunks[#chunks + 1] = build_chunk("PROP", prop_data)
		end
	end

	-- --------------------------------------------------------
	-- PRNT chunk
	-- FIX: child refs are delta-encoded; parent refs are NOT delta-encoded.
	-- Root instances get parent referent -1 (null). These go through zigzag
	-- but not delta, matching the Roblox binary format spec.
	-- --------------------------------------------------------

	do
		local child_refs  = table.create(instance_count)
		local parent_refs = table.create(instance_count)
		local order_n     = 0

		local function post_order(inst)
			for _, child in children_of[inst] or {} do
				post_order(child)
			end
			order_n += 1
			child_refs[order_n]  = referent_of[inst]
			local par            = parent_of[inst]
			parent_refs[order_n] = par and referent_of[par] or -1
		end

		for _, root in instanceList do
			post_order(root)
		end

		local count_buf = buffer.create(5)
		buffer.writeu8(count_buf, 0, 0)   -- version byte
		buffer.writeu32(count_buf, 1, order_n)

		local prnt_data = buffer.tostring(count_buf)
			.. encode_referent_array(child_refs)
			.. encode_parent_referent_array(parent_refs) -- FIX: separate encoder

		chunks[#chunks + 1] = build_chunk("PRNT", prnt_data)
	end

	-- --------------------------------------------------------
	-- END chunk (must be uncompressed)
	-- --------------------------------------------------------

	do
		local end_name    = "END\0"
		local end_payload = "</roblox>"
		local end_header  = buffer.create(16)
		buffer.writestring(end_header, 0, end_name)
		buffer.writeu32(end_header, 4, 0)
		buffer.writeu32(end_header, 8, #end_payload)
		buffer.writeu32(end_header, 12, 0)
		chunks[#chunks + 1] = buffer.tostring(end_header) .. end_payload
	end

	return table.concat(chunks)
end

return BinarySerializer
