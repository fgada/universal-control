namespace UniversalControlWindowsReceiver;

internal readonly record struct KeyboardMapping(ushort Code, bool Extended, bool UsesVirtualKey = false);

internal static class HidUsageMapper
{
    private static readonly Dictionary<ushort, KeyboardMapping> KeyMappings = new()
    {
        [0x04] = new(0x1E, false),
        [0x05] = new(0x30, false),
        [0x06] = new(0x2E, false),
        [0x07] = new(0x20, false),
        [0x08] = new(0x12, false),
        [0x09] = new(0x21, false),
        [0x0A] = new(0x22, false),
        [0x0B] = new(0x23, false),
        [0x0C] = new(0x17, false),
        [0x0D] = new(0x24, false),
        [0x0E] = new(0x25, false),
        [0x0F] = new(0x26, false),
        [0x10] = new(0x32, false),
        [0x11] = new(0x31, false),
        [0x12] = new(0x18, false),
        [0x13] = new(0x19, false),
        [0x14] = new(0x10, false),
        [0x15] = new(0x13, false),
        [0x16] = new(0x1F, false),
        [0x17] = new(0x14, false),
        [0x18] = new(0x16, false),
        [0x19] = new(0x2F, false),
        [0x1A] = new(0x11, false),
        [0x1B] = new(0x2D, false),
        [0x1C] = new(0x15, false),
        [0x1D] = new(0x2C, false),
        [0x1E] = new(0x02, false),
        [0x1F] = new(0x03, false),
        [0x20] = new(0x04, false),
        [0x21] = new(0x05, false),
        [0x22] = new(0x06, false),
        [0x23] = new(0x07, false),
        [0x24] = new(0x08, false),
        [0x25] = new(0x09, false),
        [0x26] = new(0x0A, false),
        [0x27] = new(0x0B, false),
        [0x28] = new(0x1C, false),
        [0x29] = new(0x01, false),
        [0x2A] = new(0x0E, false),
        [0x2B] = new(0x0F, false),
        [0x2C] = new(0x39, false),
        [0x2D] = new(0x0C, false),
        [0x2E] = new(0x0D, false),
        [0x2F] = new(0x1A, false),
        [0x30] = new(0x1B, false),
        [0x31] = new(0x2B, false),
        [0x33] = new(0x27, false),
        [0x34] = new(0x28, false),
        [0x35] = new(0x29, false),
        [0x36] = new(0x33, false),
        [0x37] = new(0x34, false),
        [0x38] = new(0x35, false),
        [0x39] = new(0x3A, false),
        [0x3A] = new(0x3B, false),
        [0x3B] = new(0x3C, false),
        [0x3C] = new(0x3D, false),
        [0x3D] = new(0x3E, false),
        [0x3E] = new(0x3F, false),
        [0x3F] = new(0x40, false),
        [0x40] = new(0x41, false),
        [0x41] = new(0x42, false),
        [0x42] = new(0x43, false),
        [0x43] = new(0x44, false),
        [0x44] = new(0x57, false),
        [0x45] = new(0x58, false),
        [0x46] = new(0x37, true),
        [0x47] = new(0x46, false),
        [0x49] = new(0x52, true),
        [0x4A] = new(0x47, true),
        [0x4B] = new(0x49, true),
        [0x4C] = new(0x53, true),
        [0x4D] = new(0x4F, true),
        [0x4E] = new(0x51, true),
        [0x4F] = new(0x4D, true),
        [0x50] = new(0x4B, true),
        [0x51] = new(0x50, true),
        [0x52] = new(0x48, true),
        [0x53] = new(0x45, false),
        [0x54] = new(0x35, true),
        [0x55] = new(0x37, false),
        [0x56] = new(0x4A, false),
        [0x57] = new(0x4E, false),
        [0x58] = new(0x1C, true),
        [0x59] = new(0x4F, false),
        [0x5A] = new(0x50, false),
        [0x5B] = new(0x51, false),
        [0x5C] = new(0x4B, false),
        [0x5D] = new(0x4C, false),
        [0x5E] = new(0x4D, false),
        [0x5F] = new(0x47, false),
        [0x60] = new(0x48, false),
        [0x61] = new(0x49, false),
        [0x62] = new(0x52, false),
        [0x63] = new(0x53, false),
        [0x64] = new(0x56, false),
        [0x65] = new(0x5D, true),
        [0x8A] = new(0x1C, false, true),
        [0x8B] = new(0x1D, false, true),
        [0xE0] = new(0x1D, false),
        [0xE1] = new(0x2A, false),
        [0xE2] = new(0x38, false),
        [0xE3] = new(0x5B, true),
        [0xE4] = new(0x1D, true),
        [0xE5] = new(0x36, false),
        [0xE6] = new(0x38, true),
        [0xE7] = new(0x5C, true)
    };

    private static readonly ushort[] ModifierUsagesByBit =
    {
        0xE0,
        0xE1,
        0xE2,
        0xE3,
        0xE4,
        0xE5,
        0xE6,
        0xE7
    };

    internal static bool TryGetKeyboardMapping(ushort usage, out KeyboardMapping mapping)
        => KeyMappings.TryGetValue(usage, out mapping);

    internal static bool TryGetModifierBit(ushort usage, out int bit)
    {
        for (var index = 0; index < ModifierUsagesByBit.Length; index++)
        {
            if (ModifierUsagesByBit[index] == usage)
            {
                bit = index;
                return true;
            }
        }

        bit = -1;
        return false;
    }

    internal static ushort ModifierUsageForBit(int bit) => ModifierUsagesByBit[bit];
}
