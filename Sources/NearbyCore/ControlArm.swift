/// B1.4/B1.5: the promoted-switch rule `LabSwitch.read` implements — a DEBUG build may use its control arm, and a release
/// build always uses the shipped value. Kept pure so the release rule is tested without the app target.
public enum ControlArm {
    public static func resolve(shipped: Bool, debugOverride: Bool?, debugBuild: Bool) -> Bool {
        guard debugBuild, let debugOverride else { return shipped }
        return debugOverride
    }
}
