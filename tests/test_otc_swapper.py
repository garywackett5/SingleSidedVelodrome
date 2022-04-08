import brownie
from brownie import Contract
from brownie import config
import math


def test_otc_swapper_no_strat(gov,
                              token,
                              vault,
                              strategist,
                              whale,
                              chain,
                              woofy_whale,
                              strategist_ms,
                              oxd,
                              swapper,
                              solid,
                              woofy,
                              yfi,
                              accounts):

    assert yfi.balanceOf(swapper) > 0
    assert woofy.balanceOf(swapper) > 0

    yfi_before = yfi.balanceOf(whale)
    woofy_before = woofy.balanceOf(whale)
    assert yfi_before >= 1e18
    swapper.trade(yfi, 1e18, {'from': whale})

    assert yfi_before - yfi.balanceOf(whale) == 1e18
    assert woofy.balanceOf(whale) - woofy_before == 1e18

    swapper.setTradePermission(whale, False, {'from': gov})
    woofy.approve(swapper, 2**256-1, {'from': whale})

    with brownie.reverts():
        swapper.trade(woofy, 1e18, {'from': whale})

    swapper.setTradePermission(whale, True, {'from': gov})

    swapper.trade(woofy, 1e18, {'from': whale})
    assert yfi.balanceOf(whale) == yfi_before
    assert woofy.balanceOf(whale) == woofy_before

    deposits = swapper.deposits(whale)
    assert deposits > 0

    # withdraw in both woofy and yfi
    swapper.withdrawLiquidity(woofy, deposits, {'from': whale})
    assert swapper.deposits(whale) == 0
    swapper.provideLiquidity(woofy, deposits, {'from': whale})

    assert swapper.deposits(whale) == deposits

    swapper.withdrawLiquidity(yfi, deposits, {'from': whale})
    assert swapper.deposits(whale) == 0
    swapper.provideLiquidity(yfi, deposits, {'from': whale})

    assert swapper.deposits(whale) == deposits

    # now sweep both
    # this borks accounting
    yfi_bal = yfi.balanceOf(swapper)
    woofy_bal = woofy.balanceOf(swapper)

    with brownie.reverts():
        swapper.sweep(woofy, woofy_bal, {'from': whale})

    swapper.sweep(woofy, woofy_bal, {'from': gov})
    swapper.sweep(yfi, yfi_bal, {'from': gov})

    assert 0 == yfi.balanceOf(swapper)
    assert 0 == woofy.balanceOf(swapper)


def test_otc_swapper_to_withdraw(gov,
                                 token,
                                 vault,
                                 strategist,
                                 whale,
                                 chain,
                                 amount,
                                 woofy_whale,
                                 strategist_ms,
                                 strategy,
                                 oxd,
                                 swapper,
                                 solid,
                                 woofy,
                                 yfi,
                                 accounts):

    airdrop = 0.01*1e18
    startingWhale = token.balanceOf(whale)-airdrop
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    # harvest and deploy funds
    strategy.harvest({"from": gov})

    # add a bit of yfi to simulate profit
    token.transfer(vault, airdrop, {"from": whale})

    # we are going to try to withdraw and fail
    vault.updateStrategyDebtRatio(strategy, 0, {'from': gov})

    # now sweep both
    # this borks accounting
    yfi_bal = yfi.balanceOf(swapper)
    woofy_bal = woofy.balanceOf(swapper)

    swapper.sweep(woofy, woofy_bal, {'from': gov})
    swapper.sweep(yfi, yfi_bal, {'from': gov})

    # now we should not be able to withdraw the woofy. which means it should return all yfi and keep the woofy
    t1 = strategy.harvest({"from": gov})
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] > 0
    assert t1.events['Harvested']['loss'] == 0

    assert yfi.balanceOf(strategy) == 0

    print(woofy.balanceOf(strategy))
    print(yfi.balanceOf(vault))
    # added -2 just to see if there are any other failures
    assert woofy.balanceOf(strategy) == yfi.balanceOf(vault) - airdrop - 1

    yfi.transfer(swapper, yfi.balanceOf(gov), {"from": gov})

    t1 = strategy.harvest({"from": gov})
    print(t1.events['Harvested'])
    assert t1.events['Harvested']['profit'] == 0
    assert t1.events['Harvested']['loss'] == 0
    assert t1.events['Harvested']['debtOutstanding'] == 0

    assert yfi.balanceOf(strategy) == 0
    assert woofy.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() == 0
