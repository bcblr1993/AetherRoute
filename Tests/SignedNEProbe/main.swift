import Foundation
import XCTest
let suite = XCTestSuite(name: "Controlled probe cycle integration")
suite.addTest(SignedNEProbeTests.defaultTestSuite)
suite.addTest(CycleBindingsTests.defaultTestSuite)
suite.addTest(CancellationTests.defaultTestSuite)
suite.addTest(RuntimeTests.defaultTestSuite)
suite.addTest(LeaseTests.defaultTestSuite)
suite.run()
guard let run = suite.testRun, run.executionCount == 49, run.totalFailureCount == 0 else { exit(1) }
print("native_probe_cycle_cancellation_lease_tests=49_passed")
