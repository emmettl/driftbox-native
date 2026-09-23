import DriftboxDSP

// The wavetable oscillator: a port of `modules/wavetable.ts` and the oscillator and table bank it
// takes from `dsp/wavetable.ts`.

/// Eight waveforms at eleven harmonic limits, float32 as the reference's tables are, in one
/// allocation: slot-major, each slot's levels in order from the richest. Built once, off the render
/// thread, and shared by every wavetable for as long as the program runs — the reference caches it
/// on the class for the same reason.
struct WavetableBank: @unchecked Sendable {
  let tables: UnsafePointer<Float>
  /// Where each level starts inside a slot, and how long it is. The same for every slot.
  let offsets: UnsafePointer<Int>
  let lengths: UnsafePointer<Int>
  let slotStride: Int

  /// The one bank. Touched only from `makeSource`, never from a render path.
  static let shared = build()

  /// Level `level` of waveform `slot`.
  @_noAllocation
  func table(_ slot: Int, _ level: Int) -> UnsafePointer<Float> {
    tables + slot * slotStride + offsets[level]
  }

  static func build() -> WavetableBank {
    let offsets = UnsafeMutablePointer<Int>.allocate(capacity: 11)
    let lengths = UnsafeMutablePointer<Int>.allocate(capacity: 11)
    var stride = 0
    for level in 0...10 {
      var length = (1024 >> level) * 4
      if length < 64 { length = 64 }
      offsets[level] = stride
      lengths[level] = length
      stride += length
    }
    let tables = UnsafeMutablePointer<Float>.allocate(capacity: 8 * stride)
    tables.initialize(repeating: 0, count: 8 * stride)

    for slot in 0..<8 {
      var sine = [Double](repeating: 0, count: 1025)
      var cosine = [Double](repeating: 0, count: 1025)
      for n in 1...1024 {
        let pair = harmonic(slot, n)
        sine[n] = pair.sine
        cosine[n] = pair.cosine
      }
      let base = tables + slot * stride
      for level in 0...10 {
        synth(sine, cosine, harmonics: 1024 >> level, length: lengths[level], into: base + offsets[level])
      }
      // One normalisation for the whole waveform, from its fullest table.
      var peak = 0.0
      for i in 0..<lengths[0] {
        let magnitude = abs(Double(base[i]))
        if magnitude > peak { peak = magnitude }
      }
      if peak > 0 {
        for level in 0...10 {
          let table = base + offsets[level]
          for i in 0..<lengths[level] { table[i] = Float(Double(table[i]) / peak) }
        }
      }
    }
    return WavetableBank(
      tables: UnsafePointer(tables), offsets: UnsafePointer(offsets), lengths: UnsafePointer(lengths),
      slotStride: stride)
  }

  /// One waveform's spectrum: sine and cosine amplitude for harmonic `n`.
  /// 0 Sine · 1 Triangle · 2 Organ · 3 Square · 4 Saw · 5 Vocal · 6 Pulse 25% · 7 Pulse 12%
  static func harmonic(_ slot: Int, _ n: Int) -> (sine: Double, cosine: Double) {
    let x = Double(n)
    if slot == 0 { return (n == 1 ? 1 : 0, 0) }
    if slot == 1 {
      if n & 1 == 0 { return (0, 0) }
      let sign: Double = ((n - 1) / 2) % 2 == 0 ? 1 : -1
      return (sign / Double(n * n), 0)
    }
    if slot == 2 {
      if n & (n - 1) != 0 { return (0, 0) }
      return (1 / x.squareRoot(), 0)
    }
    if slot == 3 { return (n & 1 == 1 ? 1 / x : 0, 0) }
    if slot == 4 { return (1 / x, 0) }
    if slot == 5 {
      let first = expDSP(-(((x - 7) / 2.5) * ((x - 7) / 2.5)))
      let second = expDSP(-(((x - 14) / 4) * ((x - 14) / 4)))
      return ((1 + 3 * first + 2 * second) / x, 0)
    }
    let duty = slot == 6 ? 0.25 : 0.12
    let angle = 2 * Double.pi * x * duty
    return ((1 - cosDSP(angle)) / x, sinDSP(angle) / x)
  }

  /// One table: the first `harmonics` of a spectrum, rendered into `length` samples by an inverse FFT.
  static func synth(
    _ sine: [Double], _ cosine: [Double], harmonics: Int, length: Int, into table: UnsafeMutablePointer<Float>
  ) {
    var re = [Double](repeating: 0, count: length)
    var im = [Double](repeating: 0, count: length)
    let top = min(harmonics, (length >> 1) - 1)
    if top >= 1 {
      for n in 1...top {
        let s = sine[n]
        let c = cosine[n]
        if s == 0 && c == 0 { continue }
        re[n] += c / 2
        re[length - n] += c / 2
        im[n] -= s / 2
        im[length - n] += s / 2
      }
    }
    transform(&re, &im)
    for i in 0..<length { table[i] = Float(re[i]) }
  }

  /// An in-place radix-2 inverse FFT, unscaled, in the reference's exact order of operations.
  static func transform(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    var j = 0
    var i = 1
    while i < n {
      var bit = n >> 1
      while j & bit != 0 {
        j ^= bit
        bit >>= 1
      }
      j ^= bit
      if i < j {
        var swap = re[i]
        re[i] = re[j]
        re[j] = swap
        swap = im[i]
        im[i] = im[j]
        im[j] = swap
      }
      i += 1
    }

    var span = 2
    while span <= n {
      let half = span >> 1
      let step = (2 * Double.pi) / Double(span)
      for k in 0..<half {
        let wr = cosDSP(step * Double(k))
        let wi = sinDSP(step * Double(k))
        var base = 0
        while base < n {
          let a = base + k
          let b = a + half
          let vr = re[b] * wr - im[b] * wi
          let vi = re[b] * wi + im[b] * wr
          re[b] = re[a] - vr
          im[b] = im[a] - vi
          re[a] += vr
          im[a] += vi
          base += span
        }
      }
      span <<= 1
    }
  }
}

/// A morphing wavetable oscillator: eight band-limited waveforms, position swept per sample, and
/// phase modulation beside the VCO's FM.
public struct WavetableModule {
  let sampleRate: Double
  let bank: WavetableBank
  var phase = 0.0
  /// The last phase increment and the mip level and fade it resolved to.
  var lastStep = Double.nan
  var lastLevel = 0
  var lastBlend = 0.0
  var lastExponent = Double.nan
  var lastRatio = 1.0

  init(sampleRate: Double, bank: WavetableBank) {
    self.sampleRate = sampleRate
    self.bank = bank
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitch = inlets[0]
    let fm = inlets[1]
    let pm = inlets[2]
    let positionIn = inlets[3]
    let out = outlets[0]
    let tune = params[0]
    let position = params[1]
    let index = params[2]
    for i in 0..<frames {
      let exponent = Double(tune[i]) / 12 + Double(pitch[i])
      if exponent != lastExponent {
        lastExponent = exponent
        lastRatio = exp2(exponent)
      }
      let carrier = 65.40639132514966 * lastRatio
      var frequency = carrier + carrier * Double(fm[i])
      if !(frequency > 0) { frequency = 0 }
      var dt = frequency / sampleRate
      if dt > 0.5 { dt = 0.5 }
      out[i] = Float(
        next(
          dt, position: Double(position[i]) + Double(positionIn[i]), offset: Double(pm[i]) * Double(index[i]))
      )
    }
  }

  /// One sample of the oscillator: `dsp/wavetable.ts`'s `next`.
  @_noAllocation
  mutating func next(_ dt: Double, position: Double, offset: Double) -> Double {
    var step = dt
    if !(step > 0) { step = 0 } else if step > 0.5 { step = 0.5 }

    phase += step
    if phase >= 1 { phase -= 1 }

    var pos = position
    if !(pos > 0) { pos = 0 } else if pos > 1 { pos = 1 }
    let scaled = pos * 7
    var slot = Int(scaled)
    if slot > 6 { slot = 6 }
    let morph = scaled - Double(slot)

    if step != lastStep {
      lastStep = step
      var limit = step > 0 ? log2DSP(2048 * step) : -20
      if limit > 10 { limit = 10 }
      var sharp = jsCeil(limit)
      if sharp < 0 { sharp = 0 }
      var blend = (limit - (sharp - 0.5)) * 2
      if blend < 0 { blend = 0 } else if blend > 1 { blend = 1 }
      lastLevel = Int(sharp)
      lastBlend = blend
    }
    let sharp = lastLevel
    let blend = lastBlend
    var dull = sharp + 1
    if dull > 10 { dull = 10 }

    var t = phase + offset
    t -= jsFloor(t)
    if !(t >= 0 && t < 1) { t = 0 }

    let low =
      read(slot, sharp, t) * (1 - blend) + read(slot, dull, t) * blend
    let high =
      read(slot + 1, sharp, t) * (1 - blend) + read(slot + 1, dull, t) * blend
    return low + (high - low) * morph
  }

  /// One linearly interpolated table read.
  @_noAllocation
  func read(_ slot: Int, _ level: Int, _ t: Double) -> Double {
    let table = bank.table(slot, level)
    let length = bank.lengths[level]
    let x = t * Double(length)
    var i = Int(x)
    if i >= length { i = length - 1 }
    var j = i + 1
    if j >= length { j = 0 }
    let frac = x - Double(i)
    return Double(table[i]) + (Double(table[j]) - Double(table[i])) * frac
  }
}
