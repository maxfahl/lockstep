import Testing
import LockstepAudio
import LockstepCore

@Test func audioSeesCoreSampleRate() {
    #expect(Lockstep.sampleRate == 48_000)
}
