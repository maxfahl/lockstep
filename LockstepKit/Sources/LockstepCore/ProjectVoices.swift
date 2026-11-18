import Foundation

// Giving a track a Voice: the section "Voice" in the panel on the right.
//
//     store.edit("Choose Voice") { $0.setTrack(trackID, voice: VoicePresets.builtIn[0].voice) }
//     store.edit("Change Voice") { $0.setTrack(trackID, voice: turned) }       // a knob let go, "Custom"
//     store.edit("Turn Voice Off") { $0.setTrack(trackID, voice: off) }        // the same Voice with `isOn` false
//
// What the other edits do with a Voice. It belongs to the track, and a clip has nothing of it:
// - Duplicate Track keeps it (`duplicateTrack`), so the copy is heard from the very voices the original is.
// - After Merge Into, the clips that came follow the Voice of the track they came to, and the Voice of the
//   track that is removed goes with it (`mergeTrack`).
// - A clip that is moved or pasted to another track follows that track, as does a take recorded there.
// - Renaming, muting, reordering, a Sound and effects leave it alone.

extension Project {
    /// Gives a track a Voice, or takes it away with nil. One edit for all of it: a preset chosen, a knob let
    /// go, Natural switched, and the switch, which hands in the same Voice with `isOn` changed.
    ///
    /// A Voice that is switched off stays on the track with its knobs, so nothing is lost by comparing with
    /// Max's own voice. The knobs are already inside their range and on a step (`VoiceKnobs`).
    ///
    /// - Returns: false when the track has exactly that already, or the project has no such track. The app
    ///   then leaves out the undo step.
    @discardableResult
    public mutating func setTrack(_ id: Track.ID, voice: TrackVoice?) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }), tracks[index].voice != voice else { return false }
        tracks[index].voice = voice
        return true
    }
}
