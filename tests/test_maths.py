import brownie
from brownie import Contract
from brownie import config
import math

# test passes as of 21-06-26


def test_maths_small_arb(gov,
                         token,
                         vault,
                         strategist,
                         whale,
                         chain,
                         amount,
                         woofy_whale,
                         strategist_ms,
                         strategy,
                         solidly_router,
                         sex,
                         swapper,
                         solid,
                         woofy,
                         yfi,
                         accounts):

    lp = strategy.lpToken()
    # test the maths
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    old_ratio = yfi_lp/woofy_lp
    print('ratio in  lp ', old_ratio)

    # now we do a big trade to mess up the lp
    yfi_bal = yfi.balanceOf(whale)
    token.approve(solidly_router, 2 ** 256 - 1, {"from": whale})
    solidly_router.swapExactTokensForTokensSimple(
        amount/2, 0, yfi, woofy, False, whale, 2**256-1, {'from': whale})

    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in  lp ', new_ratio)

    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    strategy.harvest({"from": gov})

    assert strategy.balanceOfLPStaked() > 0
    print(strategy.estimatedTotalAssets())

    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after harvest ', new_ratio)


def test_maths_unequal_pool(gov,
                            token,
                            vault,
                            strategist,
                            whale,
                            chain,
                            amount,
                            woofy_whale,
                            strategist_ms,
                            strategy,
                            solidly_router,
                            sex,
                            swapper,
                            solid,
                            woofy,
                            yfi,
                            accounts):

    lp = strategy.lpToken()
    # test the maths
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    old_ratio = yfi_lp/woofy_lp
    print('ratio in  lp ', old_ratio)

    # now we do a big trade to mess up the lp
    yfi_bal = yfi.balanceOf(whale)
    token.approve(solidly_router, 2 ** 256 - 1, {"from": whale})
    solidly_router.swapExactTokensForTokensSimple(
        yfi_bal-amount, 0, yfi, woofy, False, whale, 2**256-1, {'from': whale})

    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in  lp ', new_ratio)

    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    strategy.harvest({"from": gov})
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after harvest ', new_ratio)

    # we havent done anything
    assert strategy.balanceOfLPStaked() == 0
    print(strategy.estimatedTotalAssets())
    assert strategy.estimatedTotalAssets() > amount

    # should be profits
    strategy.setDoHealthCheck(False, {"from": gov})
    t1 = strategy.harvest({"from": gov})
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after harvest2 ', new_ratio)
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0

    # now we withdraw all to make sure the profit is real
    vault.updateStrategyDebtRatio(strategy, 0, {'from': gov})
    strategy.setDoHealthCheck(False, {"from": gov})
    t1 = strategy.harvest({"from": gov})
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0
    assert t1.events['Harvested']['debtOutstanding'] == 0

    assert strategy.estimatedTotalAssets() == 0


def test_maths_big_arb_after_deposit(gov,
                                     token,
                                     vault,
                                     strategist,
                                     whale,
                                     chain,
                                     amount,
                                     woofy_whale,
                                     strategist_ms,
                                     strategy,
                                     solidly_router,
                                     sex,
                                     swapper,
                                     solid,
                                     woofy,
                                     yfi,
                                     accounts):

    lp = strategy.lpToken()
    # test the maths
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    old_ratio = yfi_lp/woofy_lp
    print('ratio in  lp ', old_ratio)

    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    strategy.harvest({"from": gov})
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after harvest ', new_ratio)

    # now we do a big trade to mess up the lp
    yfi_bal = yfi.balanceOf(whale)
    token.approve(solidly_router, 2 ** 256 - 1, {"from": whale})
    solidly_router.swapExactTokensForTokensSimple(
        yfi_bal, 0, yfi, woofy, False, whale, 2**256-1, {'from': whale})

    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after bad trade', new_ratio)

    assert strategy.estimatedTotalAssets() > amount

    # should be profits
    strategy.setDoHealthCheck(False, {"from": gov})
    t1 = strategy.harvest({"from": gov})
    yfi_lp = yfi.balanceOf(lp)
    woofy_lp = woofy.balanceOf(lp)
    new_ratio = yfi_lp/woofy_lp
    print('ratio in lp after harvest2 ', new_ratio)
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0

    # now we withdraw all to make sure the profit is real
    vault.updateStrategyDebtRatio(strategy, 0, {'from': gov})
    strategy.setDoHealthCheck(False, {"from": gov})
    t1 = strategy.harvest({"from": gov})
    print(strategy.estimatedTotalAssets())
    print(yfi.balanceOf(swapper))
    print(woofy.balanceOf(swapper))
    print(yfi.balanceOf(strategy))
    print(woofy.balanceOf(strategy))
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0
    assert t1.events['Harvested']['debtOutstanding'] > 0

    # we made money from arbing during liquidations
    strategy.setDoHealthCheck(False, {"from": gov})
    t1 = strategy.harvest({"from": gov})
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0
    assert t1.events['Harvested']['debtOutstanding'] == 0

    assert strategy.estimatedTotalAssets() == 0
