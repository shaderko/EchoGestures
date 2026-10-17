import Foundation

struct SonarComplexProfile: Codable {
    let real: [Float]
    let imaginary: [Float]
    static let empty=Self(real:[],imaginary:[])
    var valid: Bool { real.count==240 && imaginary.count==240 && real.allSatisfy(\.isFinite) && imaginary.allSatisfy(\.isFinite) }
    var magnitude: [Float] { valid ? zip(real,imaginary).map{hypot($0,$1)} : [] }
    func subtract(_ baseline: Self) -> Self {
        guard valid, baseline.valid else { return self }
        return Self(real:zip(real,baseline.real).map(-),imaginary:zip(imaginary,baseline.imaginary).map(-))
    }
    // Remove the carrier before interpolation, then reference to the direct path.
    // This cancels common capture phase instead of mistaking it for reflector movement.
    static func referenced(real: [Float], imaginary: [Float], direct: Int, rate: Double, carrier: Double, normalization: Float) -> Self {
        commonReferenced(real: real, imaginary: imaginary, referenceReal: real, referenceImaginary: imaginary,
                         direct: direct, rate: rate, carrier: carrier, normalization: normalization)
    }
    static func commonReferenced(real: [Float], imaginary: [Float], referenceReal: [Float], referenceImaginary: [Float],
                                 direct: Int, rate: Double, carrier: Double, normalization: Float) -> Self {
        guard !real.isEmpty, real.count==imaginary.count, referenceReal.count == real.count,
              referenceImaginary.count == real.count, direct>=0, direct<real.count, rate>0,carrier>0 else { return .empty }
        let omega=2 * Double.pi*carrier/rate, n=real.count
        func demod(_ index: Int) -> (Double,Double) {
            let j=(index%n+n)%n, a = -omega*Double(index), c=cos(a), s=sin(a)
            return (Double(real[j])*c-Double(imaginary[j])*s,Double(real[j])*s+Double(imaginary[j])*c)
        }
        let angle = -omega * Double(direct)
        let ref = (Double(referenceReal[direct]) * cos(angle) - Double(referenceImaginary[direct]) * sin(angle),
                   Double(referenceReal[direct]) * sin(angle) + Double(referenceImaginary[direct]) * cos(angle))
        let magnitude=hypot(ref.0,ref.1)
        guard magnitude>1e-10 else { return .empty }
        let rr=ref.0/magnitude, ri=ref.1/magnitude, scale=1/Double(max(normalization,1e-12))
        var r:[Float]=[], q:[Float]=[]
        for i in 0..<240 {
            let index=Double(direct)+Double(i)*1.4/239*2/343*rate, lo=Int(floor(index)), fraction=index-Double(lo)
            let a=demod(lo), b=demod(lo+1)
            let x=a.0+(b.0-a.0)*fraction, y=a.1+(b.1-a.1)*fraction
            r.append(Float((x*rr+y*ri)*scale)); q.append(Float((y*rr-x*ri)*scale))
        }
        return Self(real:r,imaginary:q)
    }
}
