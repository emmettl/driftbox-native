#if os(macOS)
  import AVFoundation
  import DriftboxHost
  import DriftboxHostMac
  import Foundation
  import Testing

  /// The devices sound can come in from, and a unit kept listening to the right one. These run
  /// against whatever this Mac has. A Mac with no input at all, as a CI runner often is, has
  /// nothing here to hear; one that has not let this process listen has nothing to hear either,
  /// and is not asked here, where nobody is there to answer.
  @MainActor
  struct AudioInputTests {
    /// Whether this process may listen: without it a unit opens and hears only silence.
    static var mayListen: Bool { AVAudioApplication.shared.recordPermission == .granted }

    @Test func theSystemsOwnInputIsListedWithANameAndAUID() {
      guard let system = AudioInputs.systemDefault() else { return }
      #expect(!system.uid.isEmpty && !system.name.isEmpty)
      #expect(AudioInputs.all().contains(system))
    }

    /// Listed from the start, but not opened until there is somewhere to put what it hears.
    @Test func theSystemsInputIsListedAndHeardOnlyWhenAsked() {
      let input = AudioCapture()
      guard let system = input.systemDefault else { return }
      #expect(input.devices.contains(system))
      #expect(input.current == nil && input.error == nil, "not listening yet")
      guard Self.mayListen else { return }
      input.destination = LiveInput()
      #expect(input.current == system, "\(input.error ?? "")")
      #expect(input.error == nil)
      input.destination = nil
      #expect(input.current == nil)
      #expect(input.error == nil)
    }

    /// What comes in arrives at the device's pace — about the rack's rate, whatever the device's
    /// own, which is the converter's doing — and stops arriving once it is let go of. Slept
    /// through rather than run through: the device's thread writes the ring itself, and needs
    /// nothing of the main thread.
    @Test func whatComesInArrivesInRealTime() {
      guard AudioInputs.systemDefault() != nil, Self.mayListen else { return }
      let input = AudioCapture()
      let heard = LiveInput()
      input.destination = heard
      guard input.current != nil else {
        Issue.record("the system's input could not be heard: \(input.error ?? "")")
        return
      }
      // Some devices take a moment to wake; count from the first frame.
      let waking = Date()
      while heard.received == 0, Date().timeIntervalSince(waking) < 1 { Thread.sleep(forTimeInterval: 0.005) }
      let first = heard.received
      let began = Date()
      Thread.sleep(forTimeInterval: 0.5)
      let seconds = Date().timeIntervalSince(began)
      let arrived = Double(heard.received - first) / 48000
      #expect(abs(arrived - seconds) < 0.05, "heard \(arrived)s in \(seconds)s")
      input.destination = nil
      let after = heard.received
      Thread.sleep(forTimeInterval: 0.1)
      #expect(heard.received == after, "nothing arrives once let go of")
    }

    /// Choosing a device that is not there listens to the system's, and remembers the choice.
    @Test func aChoiceThatIsNotThereFallsBackToTheSystems() {
      guard let system = AudioInputs.systemDefault(), Self.mayListen else { return }
      let input = AudioCapture(chosen: "no-such-device")
      input.destination = LiveInput()
      #expect(input.current == system.device)
      #expect(input.chosen == "no-such-device")
      input.destination = nil
    }

    /// Every input there is can be opened by its UID, and heard from within a second: some take
    /// a while to wake.
    @Test func everyInputCanBeHeard() {
      guard Self.mayListen else { return }
      let input = AudioCapture()
      for device in input.devices {
        let heard = LiveInput()
        input.chosen = device.id
        input.destination = heard
        #expect(input.current == device, "\(device.name): \(input.error ?? "")")
        let began = Date()
        while heard.received == 0, Date().timeIntervalSince(began) < 1 { Thread.sleep(forTimeInterval: 0.01) }
        #expect(heard.received > 0, "\(device.name) gave nothing")
        input.destination = nil
      }
    }

    /// Where the Mac has said no, the input says so, rather than hearing silence and not saying.
    @Test func aRefusalIsSaid() {
      guard AVAudioApplication.shared.recordPermission == .denied, AudioInputs.systemDefault() != nil
      else { return }
      let input = AudioCapture()
      input.destination = LiveInput()
      #expect(input.current == nil)
      #expect(input.error == AudioCapture.refused)
    }
  }
#endif
