pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./StrategyToken.sol";

interface IWBNB is IERC20 {
    function deposit() external payable;

    function withdraw(uint wad) external;
}

contract MultiStrategyToken is StrategyToken {

    enum Lender {
        AUTOFARM,
        ACRYPTOS,
        ALPHAHOMORA,
        FORTUBE,
        VENUS,
        NONE
    }

    address public constant wbnbAddress =
    0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    bool public immutable isWbnb;

    address[] public strategies;

    mapping(address => uint256) public ratios;

    mapping(address => bool) public isActive;

    uint256 activeCount;

    uint256 public ratioTotal;

    uint256 public rebalanceThresholdNumer;

    uint256 public rebalanceThresholdDenom;

    // btokenAddrs
    address public bAcryptos;
    address public bAutoFarm;
    address public bFortube;
    address public bAlphaHomora;
    address public bVenus;

    constructor (
        string memory name_,
        string memory symbol_,
        address _token,
        address _autoFarm,
        address _acryptos,
        address _alphaHomora,
        address _fortube,
        address _venus
    ) public ERC20(name_, symbol_) {
        govAddress = msg.sender;

        token = _token;
        strategies.push(_autoFarm);
        isActive[_autoFarm] = true;

        strategies.push(_acryptos);
        isActive[_acryptos] = true;

        strategies.push(_alphaHomora);
        isActive[_alphaHomora] = true;

        strategies.push(_fortube);
        isActive[_fortube] = true;

        strategies.push(_venus);
        isActive[_venus] = true;

        activeCount = strategies.length;

        // active except Ledner.NONE - 1;
        strategies.push(address(0));
        

        bAutoFarm = _autoFarm;
        bAcryptos = _acryptos;
        bAlphaHomora = _alphaHomora;
        bFortube = _fortube;
        bVenus = _venus;


        
        ratios[_autoFarm] = 1;
        ratios[_acryptos] = 1;
        ratios[_alphaHomora] = 1;
        ratios[_fortube] = 1;
        ratios[_venus] = 1;

        ratioTotal = ratios[_autoFarm].add(
            ratios[_acryptos]
        ).add(
            ratios[_alphaHomora]
        ).add(
            ratios[_fortube]
        ).add(
            ratios[_venus]
        );

        entranceFeeNumer = 0;
        entranceFeeDenom = 1;

        rebalanceThresholdNumer = 10;
        rebalanceThresholdDenom = 100;

        isWbnb = token == wbnbAddress;
        
        approveToken();
    }

    function deposit(uint256 _amount, uint256 _minShares)
        override
        external
    {
        require(_amount != 0, "deposit must be greater than 0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        _deposit(_amount, _minShares);
    }

    function depositBNB(uint256 _minShares) external payable {
        require(isWbnb);
        require(msg.value != 0, "deposit must be greater than 0");
        _wrapBNB(msg.value);
        _deposit(msg.value, _minShares);
    }

    function _deposit(uint256 _amount, uint256 _minShares)
        internal
        nonReentrant
    {
        uint256 _pool = calcPoolValueInToken();
        
        address strategyAddress;
        (strategyAddress,) = findMostInsufficientStrategy();
        StrategyToken(strategyAddress).deposit(_amount, 0);
        
        uint256 sharesToMint = calcPoolValueInToken().sub(_pool);
        if (totalSupply() != 0 && _pool != 0) {
            sharesToMint = (sharesToMint.mul(totalSupply()))
                .div(_pool);
        }
        require(sharesToMint >= _minShares);
        _mint(msg.sender, sharesToMint);    
    }
    

    function withdraw(uint256 _shares, uint256 _minAmount)
        override
        external
    {
        uint r = _withdraw(_shares, _minAmount);
        IERC20(token).safeTransfer(msg.sender, r);
    }

    function withdrawBNB(uint256 _shares, uint256 _minAmount)
        external
    {
        require(isWbnb);
        uint256 r = _withdraw(_shares, _minAmount);
        _unwrapBNB(r);
        msg.sender.transfer(r);
    }

    function _withdraw(uint256 _shares, uint256 _minAmount)
        internal
        nonReentrant
        returns (uint256)
    {
        require(_shares != 0, "shares must be greater than 0");

        uint256 ibalance = balanceOf(msg.sender);
        require(_shares <= ibalance, "insufficient balance");

        uint256 pool = calcPoolValueInToken();

        uint256 r = (pool.mul(_shares)).div(totalSupply());
        _burn(msg.sender, _shares);

        address strategyToWithdraw;
        uint256 strategyAvailableAmount;
        (strategyToWithdraw, strategyAvailableAmount) = findMostOverLockedStrategy(r);
        if (r > strategyAvailableAmount) {
            (strategyToWithdraw, strategyAvailableAmount) = findMostLockedStrategy();
            require(r <= strategyAvailableAmount, 'withdrawal amount too big');
        }
        uint256 _stratPool = StrategyToken(strategyToWithdraw).calcPoolValueInToken();
        uint256 stratShares = r
            .mul(
                IERC20(strategyToWithdraw).totalSupply()
            )
            .div(_stratPool);
        uint256 diff = balance();
        StrategyToken(strategyToWithdraw).withdraw(stratShares, 0/*strategyAvailableAmount*/);
        diff = balance().sub(diff);
        
        require(diff >= _minAmount);

        return diff;
    }

    function rebalance() public {
        require(msg.sender == govAddress);
        address strategyToWithdraw;
        uint256 strategyAvailableAmount;
        address strategyToDeposit;
        // uint256 strategyInsuffAmount;
        (strategyToWithdraw, strategyAvailableAmount) = findMostOverLockedStrategy(0);
        (strategyToDeposit, /*strategyInsuffAmount*/) = findMostInsufficientStrategy();

        uint256 totalBalance = calcPoolValueInToken();
        uint256 optimal = totalBalance.mul(ratios[strategyToWithdraw]).div(ratioTotal);

        uint256 threshold = optimal.mul(
            rebalanceThresholdDenom.add(
                rebalanceThresholdNumer
            ).div(rebalanceThresholdDenom)
        );

        if (strategyAvailableAmount != 0 && threshold < strategyAvailableAmount) {
            uint256 _pool = StrategyToken(strategyToWithdraw).calcPoolValueInToken();
            uint256 stratShares = strategyAvailableAmount
                    .mul(
                        IERC20(strategyToWithdraw).totalSupply()
                    )
                    .div(_pool);
            uint256 diff = balance();
            StrategyToken(strategyToWithdraw).withdraw(stratShares, 0/*strategyAvailableAmount)*/);
            diff = balance().sub(diff);
            StrategyToken(strategyToDeposit).deposit(diff, 0);
        }
    }

    function findMostOverLockedStrategy(uint256 withdrawAmt) public view returns (address, uint256) {
        address[] memory strats = getAvailableStrategyList();

        uint256 totalBalance = calcPoolValueInToken().sub(withdrawAmt);

        address overLockedStrategy = strats[0];

        uint256 optimal = totalBalance.mul(ratios[strats[0]]).div(ratioTotal);
        uint256 current = StrategyToken(strats[0]).calcPoolValueInToken();   
        
        bool isLessThanOpt = current < optimal;
        uint256 overLockedBalance = isLessThanOpt ? optimal.sub(current) : current.sub(optimal);

        uint256 i = 1;
        for (; i < strats.length; i += 1) {
            optimal = totalBalance.mul(ratios[strats[i]]).div(ratioTotal);
            current = StrategyToken(strats[i]).calcPoolValueInToken(); 
            if (isLessThanOpt && current >= optimal) {
                isLessThanOpt = false;
                overLockedBalance = current.sub(optimal);
                overLockedStrategy = strats[i];
            } else if (isLessThanOpt && current < optimal) {
                if (optimal.sub(current) < overLockedBalance) {
                    overLockedBalance = optimal.sub(current);
                    overLockedStrategy = strats[i];
                }
            } else if (!isLessThanOpt && current >= optimal) {
                if (current.sub(optimal) > overLockedBalance) {
                    overLockedBalance = current.sub(optimal);
                    overLockedStrategy = strats[i];
                }
            }
        }

        if (isLessThanOpt) {
            overLockedBalance = 0;
        }

        return (overLockedStrategy, overLockedBalance);
    }

    function findMostLockedStrategy() public view returns (address, uint256) {
        address[] memory strats = getAvailableStrategyList();

        uint256 current;
        address lockedMostAddr = strats[0];
        uint256 lockedBalance = StrategyToken(strats[0]).calcPoolValueInToken();

        uint256 i = 1;
        for (; i < strats.length; i += 1) {
            current = StrategyToken(strats[i]).calcPoolValueInToken(); 
            if (current > lockedBalance) {
                lockedBalance = current;
                lockedMostAddr = strats[i];
            }
        }

        return (lockedMostAddr, lockedBalance);
    }

    function findMostInsufficientStrategy() public view returns (address, uint256) {
        address[] memory strats = getAvailableStrategyList();

        uint256 totalBalance = calcPoolValueInToken();

        address insuffStrategy = strats[0];

        uint256 optimal = totalBalance.mul(ratios[strats[0]]).div(ratioTotal);
        uint256 current = StrategyToken(strats[0]).calcPoolValueInToken();   
        
        bool isGreaterThanOpt = current > optimal;
        uint256 insuffBalance = isGreaterThanOpt ? current.sub(optimal) : optimal.sub(current);

        uint256 i = 1;
        for (; i < strats.length; i += 1) {
            optimal = totalBalance.mul(ratios[strats[i]]).div(ratioTotal);
            current = StrategyToken(strats[i]).calcPoolValueInToken(); 
            if (isGreaterThanOpt && current < optimal) {
                isGreaterThanOpt = false;
                insuffBalance = optimal.sub(current);
                insuffStrategy = strats[i];
            } else if (isGreaterThanOpt && current > optimal) {
                if (current.sub(optimal) < insuffBalance) {
                    insuffBalance = current.sub(optimal);
                    insuffStrategy = strats[i];
                }
            } else if (!isGreaterThanOpt && current <= optimal) {
                if (optimal.sub(current) > insuffBalance) {
                    insuffBalance = optimal.sub(current);
                    insuffStrategy = strats[i];
                }
            }
        }

        if (isGreaterThanOpt) {
            insuffBalance = 0;
        }

        return (insuffStrategy, insuffBalance);
    }

    function approveToken() public {
        uint i = 0;
        for (; i < uint(Lender.NONE); i += 1) {
            IERC20(token).safeApprove(strategies[i], uint(-1));   
        }
        // IERC20(token).safeApprove(bAutoFarm, uint(-1));
        // IERC20(token).safeApprove(bAcryptos, uint(-1));
        // IERC20(token).safeApprove(bAlphaHomora, uint(-1));
        // IERC20(token).safeApprove(bFortube, uint(-1));
        // IERC20(token).safeApprove(bVenus, uint(-1));
    }

    function balance() override public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function balanceStrategy() override public view returns (uint256) {
        uint i = 0;
        uint sum = 0;
        StrategyToken stToken;
        for (; i < uint(Lender.NONE); i += 1) {
            stToken = StrategyToken(strategies[i]);
            sum = sum.add(stToken.calcPoolValueInToken().mul(
                stToken.balanceOf(address(this))
            ).div(
                stToken.totalSupply()
            ));
        }
        return sum;
    }

    function getAvailableStrategyList() internal view returns (address[] memory) {
        require(activeCount != 0);
        address[] memory addrArr = new address[](activeCount);
        uint256 i = 0;
        uint256 cnt = 0;
        for (; i < uint256(Lender.NONE); i += 1) {
            if (isActive[strategies[i]]) {
                addrArr[cnt] = strategies[i];
                cnt += 1;
            }
        }
        return addrArr;
    }

    function calcPoolValueInToken() override public view returns (uint256) {
        return balanceStrategy();
    }

    function getPricePerFullShare() override public view returns (uint) {
        uint _pool = calcPoolValueInToken();
        return _pool.mul(uint256(10) ** uint256(decimals())).div(totalSupply());
    }

    function changeRatio(uint256 index, uint256 value) external onlyOwner {
        // require(index != 0);
        require(uint256(Lender.NONE) > index);
        uint256 valueBefore = ratios[strategies[index]];
        ratios[strategies[index]] = value;    
        ratioTotal = ratioTotal.sub(valueBefore).add(value);
    }

    function sharesToAmount(uint256 _shares) override public view returns (uint256) {
        uint256 _pool = calcPoolValueInToken();
        return _shares.mul(_pool).div(totalSupply());
    }

    function amountToShares(uint256 _amount) override public view returns (uint256) {
        uint256 _pool = calcPoolValueInToken();
        uint256 shares;
        if (totalSupply() == 0 || _pool == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply()))
                .div(_pool);
        }
        return shares;
    }

    function setGovAddress(address _govAddress) override public {
        require(msg.sender == govAddress, "Not authorized");
        govAddress = _govAddress;
    }

    function setEntranceFee(uint256 _entranceFeeNumer, uint256 _entranceFeeDenom) override external {
        revert();
    }
    
    function setRebalanceThreshold(uint256 _rebalanceThresholdNumer, uint256 _rebalanceThresholdDenom) external {
        require(msg.sender == govAddress, "Not authorized");
        require(_rebalanceThresholdDenom != 0);
        require(_rebalanceThresholdDenom >= _rebalanceThresholdNumer);
        rebalanceThresholdNumer = _rebalanceThresholdNumer;
        rebalanceThresholdDenom = _rebalanceThresholdDenom;
    }

    function setStrategyActive(uint256 index, bool b) public {
        require(msg.sender == govAddress);
        require(index < uint256(Lender.NONE));
        require(isActive[strategies[index]] != b);
        activeCount = b ? activeCount.add(1) : activeCount.sub(1);
        isActive[strategies[index]] = b;
    }

    function _wrapBNB(uint256 _amount) internal {
        if (address(this).balance >= _amount) {
            IWBNB(wbnbAddress).deposit{value: _amount}();
        }
    }

    function _unwrapBNB(uint256 _amount) internal {
        uint256 wbnbBal = IERC20(wbnbAddress).balanceOf(address(this));
        if (wbnbBal >= _amount) {
            IWBNB(wbnbAddress).withdraw(_amount);
        }
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) public {
        require(msg.sender == govAddress, "!gov");
        require(_token != address(this), "!safe");
        if (_token == address(0)) {
            require(address(this).balance >= _amount);
            _wrapBNB(_amount);
        } else if (_token == token) { 
            require(balance() >= _amount);
        }
        IERC20(_token).safeTransfer(_to, _amount);
    }

    receive() external payable {}
}