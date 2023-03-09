# @version 0.2.4
"""
@title Voting Escrow
@author Curve Finance
@license MIT
@notice Votes have a weight depending on time, so that users are
        committed to the future of (whatever they are voting for)
@dev Vote weight decays linearly over time. Lock time cannot be
     more than `MAXTIME` (4 years).
"""

# Voting escrow to have time-weighted votes
# Votes have a weight depending on time, so that users are committed
# to the future of (whatever they are voting for).
# The weight in this implementation is linear, and lock cannot be more than maxtime:
# w ^
# 1 +        /
#   |      /
#   |    /
#   |  /
#   |/
# 0 +--------+------> time
#       maxtime (4 years?)

struct Point:
    bias: int128 # 可正可负
    slope: int128  # - dweight / dt
    ts: uint256
    blk: uint256  # block
# We cannot really do block numbers per se b/c slope is per time, not per block
# and per block could be fairly bad b/c Ethereum changes blocktimes.
# What we can do is to extrapolate ***At functions

struct LockedBalance:
    amount: int128
    end: uint256 # 注意：只定义了解锁时间，即end时间，并不需要定义start时间，因为voting power只和两个因素相关：1.存的数量 2.当前时间戳到解锁时间的时间长度


interface ERC20:
    def decimals() -> uint256: view
    def name() -> String[64]: view
    def symbol() -> String[32]: view
    def transfer(to: address, amount: uint256) -> bool: nonpayable
    def transferFrom(spender: address, to: address, amount: uint256) -> bool: nonpayable


# Interface for checking whether address belongs to a whitelisted
# type of a smart wallet.
# When new types are added - the whole contract is changed
# The check() method is modifying to be able to use caching
# for individual wallet addresses
# 用于检查一个合约是否是白名单合约
interface SmartWalletChecker:
    def check(addr: address) -> bool: nonpayable

DEPOSIT_FOR_TYPE: constant(int128) = 0
CREATE_LOCK_TYPE: constant(int128) = 1
INCREASE_LOCK_AMOUNT: constant(int128) = 2
INCREASE_UNLOCK_TIME: constant(int128) = 3


event CommitOwnership:
    admin: address

event ApplyOwnership:
    admin: address

event Deposit:
    provider: indexed(address)
    value: uint256
    locktime: indexed(uint256)
    type: int128
    ts: uint256

event Withdraw:
    provider: indexed(address)
    value: uint256
    ts: uint256

event Supply:
    prevSupply: uint256
    supply: uint256


WEEK: constant(uint256) = 7 * 86400  # all future times are rounded by week
MAXTIME: constant(uint256) = 4 * 365 * 86400  # 4 years
MULTIPLIER: constant(uint256) = 10 ** 18

token: public(address)
supply: public(uint256)

locked: public(HashMap[address, LockedBalance])

epoch: public(uint256)
point_history: public(Point[100000000000000000000000000000])  # epoch -> unsigned point
user_point_history: public(HashMap[address, Point[1000000000]])  # user -> Point[user_epoch]
user_point_epoch: public(HashMap[address, uint256])
slope_changes: public(HashMap[uint256, int128])  # time -> signed slope change

# Aragon's view methods for compatibility
controller: public(address)
transfersEnabled: public(bool)

name: public(String[64])
symbol: public(String[32])
version: public(String[32])
decimals: public(uint256)

# Checker for whitelisted (smart contract) wallets which are allowed to deposit
# The goal is to prevent tokenizing the escrow
future_smart_wallet_checker: public(address)
smart_wallet_checker: public(address)

admin: public(address)  # Can and will be a smart contract
future_admin: public(address)


@external
def __init__(token_addr: address, _name: String[64], _symbol: String[32], _version: String[32]):
    """
    @notice Contract constructor
    @param token_addr `ERC20CRV` token address
    @param _name Token name
    @param _symbol Token symbol
    @param _version Contract version - required for Aragon compatibility
    """
    self.admin = msg.sender # 谁部署，谁就是合约的admin
    self.token = token_addr # CRV的地址，即治理代币的地址
    self.point_history[0].blk = block.number # 当前区块号作为point_history第一个元素的区块号
    self.point_history[0].ts = block.timestamp # 当前区块时间戳作为point_history第一个元素的时间戳
    self.controller = msg.sender # 谁部署，谁就是合约的controller
    self.transfersEnabled = True

    # 把CRV的decimals设置为veCRV的decimals
    _decimals: uint256 = ERC20(token_addr).decimals()
    assert _decimals <= 255
    self.decimals = _decimals

    self.name = _name # ERC20 name
    self.symbol = _symbol # ERC20 symbol
    self.version = _version # 版本，这个暂时不知道用途


@external
def commit_transfer_ownership(addr: address):
    """
    @notice Transfer ownership of VotingEscrow contract to `addr`
    @param addr Address to have ownership transferred to
    """
    assert msg.sender == self.admin  # dev: admin only
    self.future_admin = addr
    log CommitOwnership(addr)


@external
def apply_transfer_ownership():
    """
    @notice Apply ownership transfer
    """
    assert msg.sender == self.admin  # dev: admin only
    _admin: address = self.future_admin
    assert _admin != ZERO_ADDRESS  # dev: admin not set
    self.admin = _admin
    log ApplyOwnership(_admin)


@external
def commit_smart_wallet_checker(addr: address):
    """
    @notice Set an external contract to check for approved smart contract wallets
    @param addr Address of Smart contract checker
    """
    assert msg.sender == self.admin
    self.future_smart_wallet_checker = addr


@external
def apply_smart_wallet_checker():
    """
    @notice Apply setting external contract to check approved smart contract wallets
    """
    assert msg.sender == self.admin
    self.smart_wallet_checker = self.future_smart_wallet_checker

# 检查一个合约是否是白名单合约
@internal
def assert_not_contract(addr: address):
    """
    @notice Check if the call is from a whitelisted smart contract, revert if not
    @param addr Address to be checked
    """
    if addr != tx.origin: # 如果addr不等于tx.origin，说明addr是一个智能合约
        checker: address = self.smart_wallet_checker # self.smart_wallet_checker是一个合约，用途是检查其他合约是否是白名单合约
        if checker != ZERO_ADDRESS: # 如果白名单地址存在
            if SmartWalletChecker(checker).check(addr): # 检查addr是否是白名单合约
                return # 是白名单合约
        raise "Smart contract depositors not allowed" # 不是白名单合约，抛异常


@external
@view
def get_last_user_slope(addr: address) -> int128:
    """
    @notice Get the most recently recorded rate of voting power decrease for `addr`
    @param addr Address of the user wallet
    @return Value of the slope
    """
    uepoch: uint256 = self.user_point_epoch[addr]
    return self.user_point_history[addr][uepoch].slope


@external
@view
def user_point_history__ts(_addr: address, _idx: uint256) -> uint256:
    """
    @notice Get the timestamp for checkpoint `_idx` for `_addr`
    @param _addr User wallet address
    @param _idx User epoch number
    @return Epoch time of the checkpoint
    """
    return self.user_point_history[_addr][_idx].ts


@external
@view
def locked__end(_addr: address) -> uint256:
    """
    @notice Get timestamp when `_addr`'s lock finishes
    @param _addr User wallet
    @return Epoch time of the lock end
    """
    return self.locked[_addr].end

# 在deposit，增加amount，延长解锁时间，以及withdraw时调用
# 这个方法是这个合约里最重要的，包含很多核心逻辑
@internal
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):#TODO
    """
    @notice Record global and per-user data to checkpoint
    @param addr User's wallet address. No user checkpoint if 0x0
    @param old_locked Pevious locked amount / end lock time for the user
    @param new_locked New locked amount / end lock time for the user
    """
    # 记录全局数据和用户个人的数据，持久化起来
    # old_locked代表上次锁定的数量和解锁时间
    # new_locked代表本次锁定的数量和解锁时间
    u_old: Point = empty(Point) # 初始化空的Point
    u_new: Point = empty(Point)
    old_dslope: int128 = 0
    new_dslope: int128 = 0
    _epoch: uint256 = self.epoch

    if addr != ZERO_ADDRESS:
        # 以下更新全局变量
        # Calculate slopes and biases
        # Kept at zero when they have to
        if old_locked.end > block.timestamp and old_locked.amount > 0: # 还没过期，amount大于0
            # MAXTIME是4年，如果1000个CRV，质押4年，就能得到1000个veCRV，即1000 voting power
            # 如果old_locked.end - block.timestamp刚好是4年，那么，bias就等于1000,和CRV数量一致
            # 如果old_locked.end - block.timestamp刚好是1年，那么，bias就等于250,是CRV数量的1/4
            # 如果old_locked.end - block.timestamp刚好是半年，那么，bias就等于250/2,是CRV数量的1/8
            # 总之，就是以4年为基准，4年就是1比1.
            # 先算出4年中每一秒的数量，即slope，然后再把当前时刻离过期的时间差，乘以slope，就得到了当前时刻的voting power
            u_old.slope = old_locked.amount / MAXTIME
            u_old.bias = u_old.slope * convert(old_locked.end - block.timestamp, int128)
        if new_locked.end > block.timestamp and new_locked.amount > 0:
            u_new.slope = new_locked.amount / MAXTIME
            u_new.bias = u_new.slope * convert(new_locked.end - block.timestamp, int128)

        # Read values of scheduled changes in the slope
        # old_locked.end can be in the past and in the future
        # new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
        old_dslope = self.slope_changes[old_locked.end]
        if new_locked.end != 0:
            if new_locked.end == old_locked.end:
                new_dslope = old_dslope # 如果new_locked和old_locked的过期时间一样
            else:
                new_dslope = self.slope_changes[new_locked.end] # 如果new_locked和old_locked的过期时间不一样

    last_point: Point = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number})
    if _epoch > 0:
        last_point = self.point_history[_epoch] # 最近的历史Point
    last_checkpoint: uint256 = last_point.ts # 最近的历史Point时间戳
    # initial_last_point is used for extrapolation to calculate block number
    # (approximately, for *At methods) and save them
    # as we cannot figure that out exactly from inside the contract
    initial_last_point: Point = last_point
    block_slope: uint256 = 0  # dblock/dt
    if block.timestamp > last_point.ts: # 当前时间戳大于最近的历史Point时间戳
        # 当前区块号-最近的历史Point区块号/当前区块时间戳-最近的历史Point时间戳，得到一秒钟对应的区块个数，即block_slope
        # 当前区块号-最近的历史Point区块号，那么block.timestamp == last_point.ts，那么block_slope=0
        block_slope = MULTIPLIER * (block.number - last_point.blk) / (block.timestamp - last_point.ts)
    # If last point is already recorded in this block, slope=0
    # But that's ok b/c we know the block in such case

    # Go over weeks to fill history and calculate what the current point is
    # last_checkpoint有可能是个周三，t_i就是周一0点的时间戳
    t_i: uint256 = (last_checkpoint / WEEK) * WEEK
    for i in range(255): # 每次循环快进一周，记录每周一0点的Point，并且持久化，直到快进到当前区块所在的周，目的在于对每周的情况都要持久化，记录下来
        # Hopefully it won't happen that this won't get used in 5 years!
        # If it does, users will be able to withdraw but vote weight will be broken
        t_i += WEEK # 每次循环快进一周，最大的可能会快进255周
        d_slope: int128 = 0 
        if t_i > block.timestamp:
            t_i = block.timestamp # 如果时间快进之后，t_i大于当前时间戳，那么t_i等于当前时间戳，即t_i不能大于当前时间戳
        else:
            d_slope = self.slope_changes[t_i] # TODO:没看懂
        last_point.bias -= last_point.slope * convert(t_i - last_checkpoint, int128) # bias减少，因为时间更加临近过期时间了
        last_point.slope += d_slope
        if last_point.bias < 0:  # This can happen
            last_point.bias = 0
        if last_point.slope < 0:  # This cannot happen - just in case
            last_point.slope = 0
        last_checkpoint = t_i
        last_point.ts = t_i # 把快进后的时间戳赋给last_point
        last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) / MULTIPLIER # 根据block_slope推算出来的区块号，并不一定完全精确，但没有问题，是平均值
        _epoch += 1 # _epoch就是用来计数的，每次递增1
        if t_i == block.timestamp: # 如果t_i已经快进到了当前区块所在的周
            last_point.blk = block.number # 对last_point的区块号重新赋值，覆盖掉上面的赋值。但现在不把last_point持久化到point_history中，因为这时候还没有考虑本次用户新存入或者取出的CRV，下面几行根据用户的slope前后差值和更新全局slope和bias后，才持久化全局的self.point_history[_epoch]。
            break # 只要快进到了当前的周，就跳出循环，目的在于保证从最近的历史Point到当前区块位置的每一周的情况都要持久化
        else:
            self.point_history[_epoch] = last_point # 持久化到历史Point中，注意此处_epoch是递增了1的

    self.epoch = _epoch # 更新全局epoch
    # Now point_history is filled until t=now

    if addr != ZERO_ADDRESS:
        # If last point was in this block, the slope change has been applied already
        # But in such case we have 0 slope(s)
        # 根据某个用户的slope前后差值和更新全局slope和bias，比如，某个用户新存了CRV，意味着slope增加了，并且bias增加了，那么全局的slope和bias也同步增加了
        last_point.slope += (u_new.slope - u_old.slope)
        last_point.bias += (u_new.bias - u_old.bias)
        if last_point.slope < 0:
            last_point.slope = 0
        if last_point.bias < 0:
            last_point.bias = 0

    # Record the changed point into history
    self.point_history[_epoch] = last_point # 把当前时间戳对应的全局last_point持久化，此时last_point的各个属性已经全部更新完成

    if addr != ZERO_ADDRESS:
        # Schedule the slope changes (slope is going down)
        # We subtract new_user_slope from [new_locked.end]
        # and add old_user_slope to [old_locked.end]
        if old_locked.end > block.timestamp: # 锁定的CRV还未过期
            # old_dslope was <something> - u_old.slope, so we cancel that
            old_dslope += u_old.slope
            if new_locked.end == old_locked.end: # 说明解锁时间没有变化，变化的是存入的CRV金额。到期后，全局slope就应该相应减少。
                old_dslope -= u_new.slope  # It was a new deposit, not extension
            self.slope_changes[old_locked.end] = old_dslope

        if new_locked.end > block.timestamp:
            if new_locked.end > old_locked.end:
                new_dslope -= u_new.slope  # old slope disappeared at this point
                # 业务上的含义：u_new的slope是有时间限制的，持续到new_locked.end时间戳，意味着new_locked到期后，就没有voting power了，也就没有slope了。
                # 打个地方，block.timestamp是周三，new_locked是下周一到期，那么到了下周一，new_locked到期了，对应的slope没有了，那么到时候，全局的slope就应该相应减少
                # 所以，self.slope_changes就是记录未来某个时间点，全局slope应该发生的变化，有可能是正，有可能是负
                self.slope_changes[new_locked.end] = new_dslope
            # else: we recorded it already in old_dslope

        # Now handle user history
        user_epoch: uint256 = self.user_point_epoch[addr] + 1 # 这不是全局变量，是对addr用户而言，记录的是用户最后一次更新的次数，即更新了几次了

        self.user_point_epoch[addr] = user_epoch # 更新次数
        u_new.ts = block.timestamp
        u_new.blk = block.number
        self.user_point_history[addr][user_epoch] = u_new # 把用户第N次变化后的状态持久化，包括slope,bias,timestamp,blocknumber


@internal
def _deposit_for(_addr: address, _value: uint256, unlock_time: uint256, locked_balance: LockedBalance, type: int128):
    """
    @notice Deposit and lock tokens for a user
    @param _addr User's wallet address
    @param _value Amount to deposit
    @param unlock_time New time when to unlock the tokens, or 0 if unchanged
    @param locked_balance Previous locked amount / timestamp
    """
    """
    为一个用户存储并且锁定代币
    unlock_time是代币解锁的新时间，如果不修改解锁时间，只需传入0即可
    locked_balance是之前已经锁定的数量以及时间戳
    """
    _locked: LockedBalance = locked_balance # 用一个本地变量保存
    supply_before: uint256 = self.supply # 理解为total supply

    self.supply = supply_before + _value # total supply增加_value数量
    old_locked: LockedBalance = _locked # 原先的LockedBalance，保存起来，后面要用
    # Adding to existing lock, or if a lock is expired - creating a new one
    _locked.amount += convert(_value, int128) # 把_value转换为int128，然后锁定的amount增加_value数量
    if unlock_time != 0:
        _locked.end = unlock_time # 修改解锁时间
    self.locked[_addr] = _locked # 更新后的信息持久化起来

    # Possibilities:
    # Both old_locked.end could be current or expired (>/< block.timestamp)
    # value == 0 (extend lock) or value > 0 (add to lock or extend lock)
    # _locked.end > block.timestamp (always)
    self._checkpoint(_addr, old_locked, _locked)#TODO

    if _value != 0:
        # 把_addr的代币转到本合约，前提是_addr需要approve本合约
        assert ERC20(self.token).transferFrom(_addr, self, _value)

    log Deposit(_addr, _value, _locked.end, type, block.timestamp)
    log Supply(supply_before, supply_before + _value)


@external
def checkpoint():
    """
    @notice Record global data to checkpoint
    """
    # 更新全局数据checkpoint
    self._checkpoint(ZERO_ADDRESS, empty(LockedBalance), empty(LockedBalance))


# msg.sender为某个地址（可以是自己）存CRV代币，并且锁定。_value是存的CRV的数量。
# 注意：_addr必须之前已经锁定过CRV代币。
@external
@nonreentrant('lock')
def deposit_for(_addr: address, _value: uint256):
    """
    @notice Deposit `_value` tokens for `_addr` and add to the lock
    @dev Anyone (even a smart contract) can deposit for someone else, but
         cannot extend their locktime and deposit for a brand new user
    @param _addr User's wallet address
    @param _value Amount to add to user's lock
    """
    # 取出_addr现有的LockedBalance，有两个属性：value和end
    _locked: LockedBalance = self.locked[_addr]

    assert _value > 0  # dev: need non-zero value
    # 下面两个判断意思是需要_addr本身就已经锁定了一定金额了，并且过期时间大于当前区块时间戳。如果_addr还没有锁定过代币，那么就会失败。
    assert _locked.amount > 0, "No existing lock found"
    assert _locked.end > block.timestamp, "Cannot add to expired lock. Withdraw"

    self._deposit_for(_addr, _value, 0, self.locked[_addr], DEPOSIT_FOR_TYPE)


@external
@nonreentrant('lock')
def create_lock(_value: uint256, _unlock_time: uint256):
    """
    @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
    @param _value Amount to deposit
    @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
    """
    # msg.sender存CRV代币，并且锁定到_unlock_time，_unlock_time转为整周
    self.assert_not_contract(msg.sender) # 如果msg.sender是合约，检查msg.sender是否是白名单合约
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK  # Locktime is rounded down to weeks 时间转换为整周
    _locked: LockedBalance = self.locked[msg.sender]

    assert _value > 0  # dev: need non-zero value
    assert _locked.amount == 0, "Withdraw old tokens first" # 必须之前没有存过才行
    assert unlock_time > block.timestamp, "Can only lock until time in the future" # 解锁时间必须在未来
    assert unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max" # 解锁时间不能超过4年

    self._deposit_for(msg.sender, _value, unlock_time, _locked, CREATE_LOCK_TYPE)


@external
@nonreentrant('lock')
def increase_amount(_value: uint256):
    """
    @notice Deposit `_value` additional tokens for `msg.sender`
            without modifying the unlock time
    @param _value Amount of tokens to deposit and add to the lock
    """
    # 增加锁定的数量，不修改过期时间
    self.assert_not_contract(msg.sender)
    _locked: LockedBalance = self.locked[msg.sender]

    assert _value > 0  # dev: need non-zero value
    assert _locked.amount > 0, "No existing lock found"
    assert _locked.end > block.timestamp, "Cannot add to expired lock. Withdraw"

    self._deposit_for(msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT)


@external
@nonreentrant('lock')
def increase_unlock_time(_unlock_time: uint256):
    """
    @notice Extend the unlock time for `msg.sender` to `_unlock_time`
    @param _unlock_time New epoch time for unlocking
    """
    # 延长msg.sender锁定的代币的过期时间
    self.assert_not_contract(msg.sender)
    _locked: LockedBalance = self.locked[msg.sender]
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK  # Locktime is rounded down to weeks

    assert _locked.end > block.timestamp, "Lock expired"
    assert _locked.amount > 0, "Nothing is locked"
    assert unlock_time > _locked.end, "Can only increase lock duration" # 只能延长解锁时间，不能减小解锁时间
    assert unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max" # 注意，此处是基于当前时间戳，加上4年

    self._deposit_for(msg.sender, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME)


@external
@nonreentrant('lock')
def withdraw():
    """
    @notice Withdraw all tokens for `msg.sender`
    @dev Only possible if the lock has expired
    """
    _locked: LockedBalance = self.locked[msg.sender]
    assert block.timestamp >= _locked.end, "The lock didn't expire"
    value: uint256 = convert(_locked.amount, uint256)

    old_locked: LockedBalance = _locked
    _locked.end = 0
    _locked.amount = 0
    self.locked[msg.sender] = _locked
    supply_before: uint256 = self.supply
    self.supply = supply_before - value

    # old_locked can have either expired <= timestamp or zero end
    # _locked has only 0 end
    # Both can have >= 0 amount
    self._checkpoint(msg.sender, old_locked, _locked)

    assert ERC20(self.token).transfer(msg.sender, value)

    log Withdraw(msg.sender, value, block.timestamp)
    log Supply(supply_before, supply_before - value)


# The following ERC20/minime-compatible methods are not real balanceOf and supply!
# They measure the weights for the purpose of voting, so they don't represent
# real coins.

@internal
@view
def find_block_epoch(_block: uint256, max_epoch: uint256) -> uint256:
    """
    @notice Binary search to estimate timestamp for block number
    @param _block Block to find
    @param max_epoch Don't go beyond this epoch
    @return Approximate timestamp for block
    """
    # Binary search
    _min: uint256 = 0
    _max: uint256 = max_epoch
    for i in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 1) / 2
        if self.point_history[_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@external
@view
def balanceOf(addr: address, _t: uint256 = block.timestamp) -> uint256:#TODO
    """
    @notice Get the current voting power for `msg.sender`
    @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    @param addr User wallet address
    @param _t Epoch time to return voting power at
    @return User voting power
    """
    # 获取某个地址在_t时间戳（默认是当前区块时间戳）的voting power
    # 之所以有balance0f这个接口，是为了和Aragon兼容，Aragon就需要ERC20 balanceOf
    _epoch: uint256 = self.user_point_epoch[addr] # 获取addr的状态最近一次更新是第几次
    if _epoch == 0: # 说明根本没有存过CRV，返回0
        return 0
    else:
        last_point: Point = self.user_point_history[addr][_epoch] # 根据addr最新的user point的时间戳，找到对应的Point，这个Point的bias就是在Point这个时间戳的voting power
        # 当前时间戳大概率是大于Point的时间戳的，所以，需要在Point的voting power基础上，再基于时间差再减掉一些voting power，因为越临近过期时间，voting power越小
        # 当前时间的voting power = last point的voting power - (当前时间戳-last point时间戳)*last point的斜率
        last_point.bias -= last_point.slope * convert(_t - last_point.ts, int128)
        if last_point.bias < 0:
            last_point.bias = 0
        return convert(last_point.bias, uint256)


@external
@view
def balanceOfAt(addr: address, _block: uint256) -> uint256:#TODO 此方法还没细看
    """
    @notice Measure voting power of `addr` at block height `_block`
    @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    @param addr User's wallet address
    @param _block Block to calculate the voting power at
    @return Voting power
    """
    # 获取addr在某个区块号的voting power
    # Copying and pasting totalSupply code because Vyper cannot pass by
    # reference yet
    assert _block <= block.number # 小于等于当前区块号

    # Binary search
    _min: uint256 = 0
    _max: uint256 = self.user_point_epoch[addr] # addr更新的次数，即最近一次更新是第几次。每次更新，对应的区块号也会增加。
    for i in range(128):  # Will be always enough for 128-bit numbers 2^128，二分法每次除2,除128次就绝对可以找到要找的目标值
        if _min >= _max: # 这种情况就找到了离_block最近的epoch
            break
        _mid: uint256 = (_min + _max + 1) / 2
        if self.user_point_history[addr][_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1

    upoint: Point = self.user_point_history[addr][_min]

    max_epoch: uint256 = self.epoch
    _epoch: uint256 = self.find_block_epoch(_block, max_epoch)
    point_0: Point = self.point_history[_epoch]
    d_block: uint256 = 0
    d_t: uint256 = 0
    if _epoch < max_epoch:
        point_1: Point = self.point_history[_epoch + 1]
        d_block = point_1.blk - point_0.blk
        d_t = point_1.ts - point_0.ts
    else:
        d_block = block.number - point_0.blk
        d_t = block.timestamp - point_0.ts
    block_time: uint256 = point_0.ts
    if d_block != 0:
        block_time += d_t * (_block - point_0.blk) / d_block

    upoint.bias -= upoint.slope * convert(block_time - upoint.ts, int128)
    if upoint.bias >= 0:
        return convert(upoint.bias, uint256)
    else:
        return 0


@internal
@view
def supply_at(point: Point, t: uint256) -> uint256:
    """
    @notice Calculate total voting power at some point in the past
    @param point The point (bias/slope) to start search from
    @param t Time to calculate the total voting power at
    @return Total voting power at that time
    """
    last_point: Point = point
    t_i: uint256 = (last_point.ts / WEEK) * WEEK
    for i in range(255):
        t_i += WEEK
        d_slope: int128 = 0
        if t_i > t:
            t_i = t
        else:
            d_slope = self.slope_changes[t_i]
        last_point.bias -= last_point.slope * convert(t_i - last_point.ts, int128)
        if t_i == t:
            break
        last_point.slope += d_slope
        last_point.ts = t_i

    if last_point.bias < 0:
        last_point.bias = 0
    return convert(last_point.bias, uint256)


@external
@view
def totalSupply(t: uint256 = block.timestamp) -> uint256:
    """
    @notice Calculate total voting power
    @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    @return Total voting power
    """
    _epoch: uint256 = self.epoch
    last_point: Point = self.point_history[_epoch]
    return self.supply_at(last_point, t)


@external
@view
def totalSupplyAt(_block: uint256) -> uint256:
    """
    @notice Calculate total voting power at some point in the past
    @param _block Block to calculate the total voting power at
    @return Total voting power at `_block`
    """
    assert _block <= block.number
    _epoch: uint256 = self.epoch
    target_epoch: uint256 = self.find_block_epoch(_block, _epoch)

    point: Point = self.point_history[target_epoch]
    dt: uint256 = 0
    if target_epoch < _epoch:
        point_next: Point = self.point_history[target_epoch + 1]
        if point.blk != point_next.blk:
            dt = (_block - point.blk) * (point_next.ts - point.ts) / (point_next.blk - point.blk)
    else:
        if point.blk != block.number:
            dt = (_block - point.blk) * (block.timestamp - point.ts) / (block.number - point.blk)
    # Now dt contains info on how far are we beyond point

    return self.supply_at(point, point.ts + dt)


# Dummy methods for compatibility with Aragon

@external
def changeController(_newController: address):
    """
    @dev Dummy method required for Aragon compatibility
    """
    assert msg.sender == self.controller
    self.controller = _newController
