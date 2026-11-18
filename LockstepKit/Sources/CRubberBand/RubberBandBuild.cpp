// Rubber Band Library v4.0.0 (commit 1d95888bec3ae0a17c0c4af791810d5a63f6bc35), built the way its maker
// describes for projects that do not use its own build system: this one file takes in the whole library.
//
// The library's files lie unchanged under `vendor/rubberband`, in the places they have in the maker's
// repository, because `single/RubberBandSingle.cpp` finds the others by their place relative to itself.
// On Apple systems that file chooses Apple's own FFT (vDSP, in Accelerate) by itself, so nothing is set here.
//
// Rubber Band is under the GNU General Public License: see `vendor/rubberband/COPYING` and THIRD-PARTY-NOTICES.md
// at the top of the repository.
#include "vendor/rubberband/single/RubberBandSingle.cpp"
