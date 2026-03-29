import Foundation

final class JitterModeController: @unchecked Sendable {
    private struct RelativeStep {
        let dx: Int16
        let dy: Int16
        let pauseTicksAfter: Int
    }

    private struct Vector {
        let dx: Int
        let dy: Int

        static prefix func - (value: Vector) -> Vector {
            Vector(dx: -value.dx, dy: -value.dy)
        }
    }

    private static let tickInterval = DispatchTimeInterval.milliseconds(20)

    private let timer: DispatchSourceTimer
    private let pointerSink: @Sendable (Int16, Int16) -> Void

    private var randomNumberGenerator = SystemRandomNumberGenerator()
    private var enabled = false
    private var pendingSteps: [RelativeStep] = []
    private var ticksUntilNextAction = 0

    init(queue: DispatchQueue, pointerSink: @escaping @Sendable (Int16, Int16) -> Void) {
        self.pointerSink = pointerSink

        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in
            self?.handleTick()
        }
        timer.resume()
    }

    var isEnabled: Bool {
        enabled
    }

    func toggle() -> Bool {
        enabled.toggle()
        pendingSteps.removeAll(keepingCapacity: true)
        ticksUntilNextAction = enabled ? randomIdleTicks() : 0
        return enabled
    }

    private func handleTick() {
        guard enabled else { return }

        if ticksUntilNextAction > 0 {
            ticksUntilNextAction -= 1
            return
        }

        if pendingSteps.isEmpty {
            pendingSteps = buildCycle()
        }

        guard !pendingSteps.isEmpty else {
            ticksUntilNextAction = randomIdleTicks()
            return
        }

        let step = pendingSteps.removeFirst()
        if step.dx != 0 || step.dy != 0 {
            pointerSink(step.dx, step.dy)
        }

        ticksUntilNextAction = pendingSteps.isEmpty ? randomIdleTicks() : step.pauseTicksAfter
    }

    private func buildCycle() -> [RelativeStep] {
        let outwardVector = makeOutwardVector()
        let outwardSteps = Int.random(in: 2...4, using: &randomNumberGenerator)
        let returnSteps = Int.random(in: 2...4, using: &randomNumberGenerator)

        // Nudge outward in a few tiny relative steps, pause briefly, then settle back.
        var steps = buildSteps(for: outwardVector, stepCount: outwardSteps)
        steps.append(RelativeStep(dx: 0, dy: 0, pauseTicksAfter: Int.random(in: 4...10, using: &randomNumberGenerator)))
        steps.append(contentsOf: buildSteps(for: -outwardVector, stepCount: returnSteps))

        if Bool.random(using: &randomNumberGenerator) {
            let settleVector = makeSettleVector()
            if settleVector.dx != 0 || settleVector.dy != 0 {
                steps.append(contentsOf: buildSteps(for: settleVector, stepCount: 1))
                steps.append(contentsOf: buildSteps(for: -settleVector, stepCount: 1))
            }
        }

        return steps
    }

    private func buildSteps(for vector: Vector, stepCount: Int) -> [RelativeStep] {
        let xSegments = partition(total: vector.dx, into: stepCount)
        let ySegments = partition(total: vector.dy, into: stepCount)

        var steps: [RelativeStep] = []
        for index in 0..<stepCount {
            let dx = Int16(clamping: xSegments[index])
            let dy = Int16(clamping: ySegments[index])
            guard dx != 0 || dy != 0 else { continue }

            steps.append(
                RelativeStep(
                    dx: dx,
                    dy: dy,
                    pauseTicksAfter: Int.random(in: 1...3, using: &randomNumberGenerator)
                )
            )
        }

        if steps.isEmpty {
            return [RelativeStep(dx: Int16(clamping: vector.dx), dy: Int16(clamping: vector.dy), pauseTicksAfter: 1)]
        }

        return steps
    }

    private func makeOutwardVector() -> Vector {
        while true {
            let dx = Int.random(in: -4...4, using: &randomNumberGenerator)
            let dy = Int.random(in: -4...4, using: &randomNumberGenerator)
            let manhattanDistance = abs(dx) + abs(dy)

            if manhattanDistance >= 2 && manhattanDistance <= 5 {
                return Vector(dx: dx, dy: dy)
            }
        }
    }

    private func makeSettleVector() -> Vector {
        Vector(
            dx: Int.random(in: -1...1, using: &randomNumberGenerator),
            dy: Int.random(in: -1...1, using: &randomNumberGenerator)
        )
    }

    private func partition(total: Int, into parts: Int) -> [Int] {
        guard parts > 0 else { return [] }
        guard total != 0 else { return Array(repeating: 0, count: parts) }

        let sign = total >= 0 ? 1 : -1
        let magnitude = abs(total)
        var cuts: [Int] = []

        if parts > 1 {
            for _ in 0..<(parts - 1) {
                cuts.append(Int.random(in: 0...magnitude, using: &randomNumberGenerator))
            }
            cuts.sort()
        }

        var previous = 0
        var segments: [Int] = []
        for cut in cuts + [magnitude] {
            segments.append((cut - previous) * sign)
            previous = cut
        }

        return segments
    }

    private func randomIdleTicks() -> Int {
        Int.random(in: 30...110, using: &randomNumberGenerator)
    }
}
