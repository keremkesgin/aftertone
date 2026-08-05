import SwiftUI

/// Renders the tonearm at a given angle around its pivot. Dumb by design: the state
/// machine (`TonearmController`) lives in the composite view that owns playback state —
/// this just draws whatever angle it's told (spec §7.3).
struct TonearmView: View {
    let currentAngle: Double
    let pivot: UnitPoint

    var body: some View {
        SceneAsset.image("tonearm")
            .resizable()
            .rotationEffect(.degrees(currentAngle), anchor: pivot)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: currentAngle)
    }
}
