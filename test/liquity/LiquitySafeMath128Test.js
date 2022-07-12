const testHelpers = require("../../utils/testHelpers.js")
const th = testHelpers.TestHelper

const DfrancSafeMath128Tester = artifacts.require("DfrancSafeMath128Tester")

contract('DfrancSafeMath128Tester', async accounts => {
  let mathTester

  beforeEach(async () => {
    mathTester = await DfrancSafeMath128Tester.new()
  })

  it('add(): reverts if overflows', async () => {
    const MAX_UINT_128 = th.toBN(2).pow(th.toBN(128)).sub(th.toBN(1))
    await th.assertRevert(mathTester.add(MAX_UINT_128, 1), 'LiquitySafeMath128: addition overflow')
  })

  it('sub(): reverts if underflows', async () => {
    await th.assertRevert(mathTester.sub(1, 2), 'LiquitySafeMath128: subtraction overflow')
  })
})
