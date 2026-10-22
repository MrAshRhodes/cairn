// CCAudioHandler.mm — SKELETON: audio playback state and stream access (tab "playing audio" indicator).
//
// CEF family: CefAudioHandler (GetAudioParameters, OnAudioStreamStarted, OnAudioStreamPacket,
// OnAudioStreamStopped, OnAudioStreamError). OnAudioStreamStopped is pure virtual, so an
// implementation must override it even when it only wants the start/stop state.
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetAudioHandler() and CCClient.mm call MakeAudioHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class AudioHandler final : public TabHandler, public CefAudioHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(AudioHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new AudioHandler(client);`.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefAudioHandler> MakeAudioHandler(Client&) { return nullptr; }

}  // namespace cc
