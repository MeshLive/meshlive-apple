/// Resolves a local camera preference without silently replacing a disconnected selected camera.
public enum CameraSelection {
    public static func selectedID(preferred: String, available: [String], defaultID: String?) -> String? {
        if !preferred.isEmpty { return available.contains(preferred) ? preferred : nil }
        if let defaultID, available.contains(defaultID) { return defaultID }
        return available.first
    }
}
