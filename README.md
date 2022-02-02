
# WOLOLO!

![Preview](wololo.png)

Summoning a DAO for the @cigtoken

## A MOLOCH DAO MOD

### About

Wololo is a Moloch v2 mod that aims to implement a DAO for the CEO of CryptoPunks (CIG).

Pople would deposit their LP tokens as a tribute, then the DAO would farm them to build a treasury. The DAO could also buy the CEO title and operate all the functions of the CEO.

### Changes:

1. Support Solidity 8. (Removed safemath library dependancy)

2. Reentrancy guards removed since whitelisting proposals will be removed, it's only possible to call in to trusted contracts

3. Removed `flags` from proposal and instead use two `enums` to track state and proposal types.
Also separated the proposal into two structs, separating data which is immutable and mutable.

4. Added new proposal types to manage the CEO (Harvest, BuyCeo, SetPrice, RewardTarget, DepositTax, SetBaseUri)

### WARNING: WORK IN PROGRESS
This is unfinished and not working yet, more todo.