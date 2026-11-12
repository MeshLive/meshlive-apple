/// B1.6: the two Design HC masters follow the S0 gate; each codec's explicit DEBUG argument still wins.
public enum HardwareCodecMasters {
    public static func resolve(gate: Bool, hevcOverride: Bool?, h264Override: Bool?) -> (hevc: Bool, h264: Bool) {
        (hevcOverride ?? gate, h264Override ?? gate)
    }
}
