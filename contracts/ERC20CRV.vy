# @version 0.2.4
"""
@title Curve DAO Token
@author Curve Finance
@license MIT
@notice ERC20 with piecewise-linear mining supply.
@dev Based on the ERC-20 token standard as defined at
     https://eips.ethereum.org/EIPS/eip-20
"""

from vyper.interfaces import ERC20

implements: ERC20


event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

event UpdateMiningParameters:
    time: uint256
    rate: uint256
    supply: uint256

event SetMinter:
    minter: address

event SetAdmin:
    admin: address


name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
total_supply: uint256

minter: public(address)
admin: public(address)

# General constants
YEAR: constant(uint256) = 86400 * 365

# Allocation:
# =========
# * shareholders - 30%
# * emplyees - 3%
# * DAO-controlled reserve - 5%
# * Early users - 5%
# == 43% ==
# left for inflation: 57%

# Supply parameters
INITIAL_SUPPLY: constant(uint256) = 1_303_030_303 # 初始供应量13亿，会在初始化的时候分配给合约部署者
# 一年释放2.7亿，INITIAL_RATE表示每秒释放的速度
INITIAL_RATE: constant(uint256) = 274_815_283 * 10 ** 18 / YEAR  # leading to 43% premine
# 每过一年，代币释放速率就减少
RATE_REDUCTION_TIME: constant(uint256) = YEAR
# 速度减少系数，1.1892
RATE_REDUCTION_COEFFICIENT: constant(uint256) = 1189207115002721024  # 2 ** (1/4) * 1e18
RATE_DENOMINATOR: constant(uint256) = 10 ** 18
INFLATION_DELAY: constant(uint256) = 86400 # 一天的秒数

# Supply variables
mining_epoch: public(int128)
start_epoch_time: public(uint256)
rate: public(uint256)

start_epoch_supply: uint256


@external
def __init__(_name: String[64], _symbol: String[32], _decimals: uint256):
    """
    @notice Contract constructor
    @param _name Token full name
    @param _symbol Token symbol
    @param _decimals Number of decimals for token
    """
    init_supply: uint256 = INITIAL_SUPPLY * 10 ** _decimals
    self.name = _name
    self.symbol = _symbol
    self.decimals = _decimals
    self.balanceOf[msg.sender] = init_supply # 关键：初始供应量全部都分给msg.sender，即合约部署者，是一个EOA
    self.total_supply = init_supply
    self.admin = msg.sender # 中心化管理员
    log Transfer(ZERO_ADDRESS, msg.sender, init_supply)

    # 假设当前时间是2023年5月29日MondayAM9点52分，计算之后的start_epoch_time就是
    # 2022年5月30日MondayAM9点52分，就等于一年前的今天，再快进一天
    self.start_epoch_time = block.timestamp + INFLATION_DELAY - RATE_REDUCTION_TIME
    self.mining_epoch = -1 # 初始值为-1
    self.rate = 0
    self.start_epoch_supply = init_supply

# 此方法非常关键，用于每过一年更新如下参数：
# self.start_epoch_time：增加一年
# self.mining_epoch：递增1
# self.start_epoch_supply：增加一年可以释放的代币数量
# self.rate：代币释放速度，衰减1.1892，即/1.1892
# 第一次调用比较特殊，在本合约部署一天后，当前时间戳距离初始self.start_epoch_time就会大于1年，那么就可以触发第一次调用，会更新如下值：
# self.start_epoch_time：刚好到在本合约部署一天后的时间戳
# self.mining_epoch：变为0
# self.rate：设为INITIAL_RATE
# self.start_epoch_supply：不会增加，依然保持init_supply
@internal
def _update_mining_parameters():
    """
    @dev Update mining rate and supply at the start of the epoch
         Any modifying mining call must also call this
    """
    # self.rate只会在_update_mining_parameters方法中更新，其他地方不会更新。初始值为0.
    _rate: uint256 = self.rate
    # self.start_epoch_supply的初始值是合约部署时的init_supply，也只会在_update_mining_parameters方法中更新。
    _start_epoch_supply: uint256 = self.start_epoch_supply

    # self.start_epoch_time初始值是合约部署时间的一年前的今天，再快进一天。也只会在_update_mining_parameters方法中更新。
    # 每调一次_update_mining_parameters，self.start_epoch_time就快进一年
    # 实际上，在本合约部署一天后，当前时间戳距离初始self.start_epoch_time就会大于1年，那么第一次调用_update_mining_parameters时，self.start_epoch_time就快进一年，刚好到在本合约部署一天后的时间戳
    self.start_epoch_time += RATE_REDUCTION_TIME
    # 初始值为-1,每调一次_update_mining_parameters，递增1. 也只会在_update_mining_parameters方法中更新。
    # 实际上，在本合约部署一天后，当前时间戳距离初始self.start_epoch_time就会大于1年，那么第一次调用_update_mining_parameters时，self.mining_epoch就会从-1变成0
    self.mining_epoch += 1

    if _rate == 0:
        # 第一次调_update_mining_parameters时，进入此分支
        # _rate是初始值0，那么就取INITIAL_RATE。一年释放2.7亿，INITIAL_RATE表示每秒释放的速度，即2.7亿/一年的秒数
        # 注意：首次调用此方法不会实际更新self.start_epoch_supply，只会更新self.start_epoch_time和self.mining_epoch
        _rate = INITIAL_RATE
    else:
        # 第二次调_update_mining_parameters时，进入此分支
        # 第二次：_rate是INITIAL_RATE。第三次：_rate是INITIAL_RATE/RATE_REDUCTION_COEFFICIENT(1.1892)。以此类推。
        # self.start_epoch_time已经前进了一年，那么self.start_epoch_supply就需要加上一年可以释放的代币数量，即加上代币释放速度×一年的秒数
        # 注意：可以释放的代币量意味着上限，但不一定真要实际释放这么多
        _start_epoch_supply += _rate * RATE_REDUCTION_TIME
        self.start_epoch_supply = _start_epoch_supply
        _rate = _rate * RATE_DENOMINATOR / RATE_REDUCTION_COEFFICIENT # 每过一年，代币释放速度就衰减1.1892

    self.rate = _rate

    log UpdateMiningParameters(block.timestamp, _rate, _start_epoch_supply)

# 手工更新发币参数
@external
def update_mining_parameters():
    """
    @notice Update mining rate and supply at the start of the epoch
    @dev Callable by any address, but only once per epoch
         Total supply becomes slightly larger if this function is called late
    """
    assert block.timestamp >= self.start_epoch_time + RATE_REDUCTION_TIME  # dev: too soon!  一年才能调用一次
    self._update_mining_parameters()

# 手工更新发币参数，同时返回self.start_epoch_time
@external
def start_epoch_time_write() -> uint256:
    """
    @notice Get timestamp of the current mining epoch start
            while simultaneously updating mining parameters
    @return Timestamp of the epoch
    """
    _start_epoch_time: uint256 = self.start_epoch_time
    if block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME:
        self._update_mining_parameters()
        return self.start_epoch_time
    else:
        return _start_epoch_time

# 手工更新发币参数，同时返回未来一年的start_epoch_time
@external
def future_epoch_time_write() -> uint256:
    """
    @notice Get timestamp of the next mining epoch start
            while simultaneously updating mining parameters
    @return Timestamp of the next epoch
    """
    _start_epoch_time: uint256 = self.start_epoch_time
    if block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME:
        self._update_mining_parameters()
        return self.start_epoch_time + RATE_REDUCTION_TIME
    else:
        return _start_epoch_time + RATE_REDUCTION_TIME

# 返回截止当前时间戳，代币总供应量的上限，即发币量的上限
@internal
@view
def _available_supply() -> uint256:
    return self.start_epoch_supply + (block.timestamp - self.start_epoch_time) * self.rate

# 返回截止当前时间戳，代币总供应量的上限，即发币量的上限
@external
@view
def available_supply() -> uint256:
    """
    @notice Current number of tokens in existence (claimed or unclaimed)
    """
    return self._available_supply()


@external
@view
def mintable_in_timeframe(start: uint256, end: uint256) -> uint256:
    """
    @notice How much supply is mintable from start timestamp till end timestamp
    @param start Start of the time interval (timestamp)
    @param end End of the time interval (timestamp)
    @return Tokens mintable from `start` till `end`
    """
    assert start <= end  # dev: start > end
    to_mint: uint256 = 0
    current_epoch_time: uint256 = self.start_epoch_time
    current_rate: uint256 = self.rate

    # Special case if end is in future (not yet minted) epoch
    if end > current_epoch_time + RATE_REDUCTION_TIME:
        current_epoch_time += RATE_REDUCTION_TIME
        current_rate = current_rate * RATE_DENOMINATOR / RATE_REDUCTION_COEFFICIENT

    assert end <= current_epoch_time + RATE_REDUCTION_TIME  # dev: too far in future

    for i in range(999):  # Curve will not work in 1000 years. Darn!
        if end >= current_epoch_time:
            current_end: uint256 = end
            if current_end > current_epoch_time + RATE_REDUCTION_TIME:
                current_end = current_epoch_time + RATE_REDUCTION_TIME

            current_start: uint256 = start
            if current_start >= current_epoch_time + RATE_REDUCTION_TIME:
                break  # We should never get here but what if...
            elif current_start < current_epoch_time:
                current_start = current_epoch_time

            to_mint += current_rate * (current_end - current_start)

            if start >= current_epoch_time:
                break

        current_epoch_time -= RATE_REDUCTION_TIME
        current_rate = current_rate * RATE_REDUCTION_COEFFICIENT / RATE_DENOMINATOR  # double-division with rounding made rate a bit less => good
        assert current_rate <= INITIAL_RATE  # This should never happen

    return to_mint


@external
def set_minter(_minter: address):
    """
    @notice Set the minter address
    @dev Only callable once, when minter has not yet been set
    @param _minter Address of the minter
    """
    assert msg.sender == self.admin  # dev: admin only
    # 此处只能设置一次minter，是否合理？
    assert self.minter == ZERO_ADDRESS  # dev: can set the minter only once, at creation
    self.minter = _minter
    log SetMinter(_minter)


@external
def set_admin(_admin: address):
    """
    @notice Set the new admin.
    @dev After all is set up, admin only can change the token name
    @param _admin New admin address
    """
    assert msg.sender == self.admin  # dev: admin only
    self.admin = _admin
    log SetAdmin(_admin)


@external
@view
def totalSupply() -> uint256:
    """
    @notice Total number of tokens in existence.
    """
    return self.total_supply


@external
@view
def allowance(_owner : address, _spender : address) -> uint256:
    """
    @notice Check the amount of tokens that an owner allowed to a spender
    @param _owner The address which owns the funds
    @param _spender The address which will spend the funds
    @return uint256 specifying the amount of tokens still available for the spender
    """
    return self.allowances[_owner][_spender]


@external
def transfer(_to : address, _value : uint256) -> bool:
    """
    @notice Transfer `_value` tokens from `msg.sender` to `_to`
    @dev Vyper does not allow underflows, so the subtraction in
         this function will revert on an insufficient balance
    @param _to The address to transfer to
    @param _value The amount to be transferred
    @return bool success
    """
    assert _to != ZERO_ADDRESS  # dev: transfers to 0x0 are not allowed
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    log Transfer(msg.sender, _to, _value)
    return True


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    """
     @notice Transfer `_value` tokens from `_from` to `_to`
     @param _from address The address which you want to send tokens from
     @param _to address The address which you want to transfer to
     @param _value uint256 the amount of tokens to be transferred
     @return bool success
    """
    assert _to != ZERO_ADDRESS  # dev: transfers to 0x0 are not allowed
    # NOTE: vyper does not allow underflows
    #       so the following subtraction would revert on insufficient balance
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    self.allowances[_from][msg.sender] -= _value
    log Transfer(_from, _to, _value)
    return True


@external
def approve(_spender : address, _value : uint256) -> bool:
    """
    @notice Approve `_spender` to transfer `_value` tokens on behalf of `msg.sender`
    @dev Approval may only be from zero -> nonzero or from nonzero -> zero in order
        to mitigate the potential race condition described here:
        https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender The address which will spend the funds
    @param _value The amount of tokens to be spent
    @return bool success
    """
    assert _value == 0 or self.allowances[msg.sender][_spender] == 0
    self.allowances[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@external
def mint(_to: address, _value: uint256) -> bool:
    """
    @notice Mint `_value` tokens and assign them to `_to`
    @dev Emits a Transfer event originating from 0x00
    @param _to The account that will receive the created tokens
    @param _value The amount that will be created
    @return bool success
    """
    assert msg.sender == self.minter  # dev: minter only  权限判断
    assert _to != ZERO_ADDRESS  # dev: zero address

    # 假设本合约的部署时间是2023年5月29日MondayAM9点52分，计算之后的start_epoch_time就是
    # 2022年5月30日MondayAM9点52分，就等于一年前的今天，再快进一天
    # self.start_epoch_time + RATE_REDUCTION_TIME就是2023年5月30日MondayAM9点52分
    # 也就是说，在部署CRV合约后，必须过24小时，才能进行mint
    # 为什么要做这样的设计？
    if block.timestamp >= self.start_epoch_time + RATE_REDUCTION_TIME:
        # 如果当前时间相比起最新的self.start_epoch_time，又过了一年，那么需要调用_update_mining_parameters，更新一些参数
        # 一年才能更新一次
        self._update_mining_parameters()

    _total_supply: uint256 = self.total_supply + _value
    assert _total_supply <= self._available_supply()  # dev: exceeds allowable mint amount
    self.total_supply = _total_supply

    self.balanceOf[_to] += _value # 直接给_to加余额，而不是从admin转账给_to
    log Transfer(ZERO_ADDRESS, _to, _value)

    return True

# 只能burn msg.sender自己的代币
@external
def burn(_value: uint256) -> bool:
    """
    @notice Burn `_value` tokens belonging to `msg.sender`
    @dev Emits a Transfer event with a destination of 0x00
    @param _value The amount that will be burned
    @return bool success
    """
    self.balanceOf[msg.sender] -= _value
    self.total_supply -= _value

    log Transfer(msg.sender, ZERO_ADDRESS, _value)
    return True


@external
def set_name(_name: String[64], _symbol: String[32]):
    """
    @notice Change the token name and symbol to `_name` and `_symbol`
    @dev Only callable by the admin account
    @param _name New token name
    @param _symbol New token symbol
    """
    assert msg.sender == self.admin, "Only admin is allowed to change name"
    self.name = _name
    self.symbol = _symbol
