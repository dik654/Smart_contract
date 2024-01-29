// SPDX-License-Identifier: AGPL-3.0-or-later

/// abaci.sol -- price decrease functions for auctions

// Copyright (C) 2020-2022 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.12;

interface Abacus {
    // 1st arg: initial price               [ray]
    // 2nd arg: seconds since auction start [seconds]
    // returns: current auction price       [ray]
    function price(uint256, uint256) external view returns (uint256);
}

contract LinearDecrease is Abacus {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "LinearDecrease/not-authorized");
        _;
    }

    // --- Data ---
    uint256 public tau;  // Seconds after auction start when the price reaches zero [seconds]

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    event File(bytes32 indexed what, uint256 data);

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what ==  "tau") tau = data;
        else revert("LinearDecrease/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }

    /**
     * @notice  .
     * @dev     시간에 따라 일정하게 가격이 떨어지는 경우 계산
     * @param   top  시작 가격
     * @param   dur  시작으로부터 얼마나 지났는지
     * @return  uint256  현재 가격
     */
    function price(uint256 top, uint256 dur) override external view returns (uint256) {
        if (dur >= tau) return 0;
        // tau - dur = 가격이 0이 될 때까지 앞으로 얼마나 남았는지 
        // tau = 시작시간부터 가격이 0이 될 때까지의 시간
        // (남은 시간 / 전체 시간) = 남은 비율
        return rmul(top, mul(tau - dur, RAY) / tau);
    }
}

contract StairstepExponentialDecrease is Abacus {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "StairstepExponentialDecrease/not-authorized");
        _;
    }

    // --- Data ---
    uint256 public step; // Length of time between price drops [seconds]
    uint256 public cut;  // Per-step multiplicative factor     [ray]

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    event File(bytes32 indexed what, uint256 data);

    // --- Init ---
    // @notice: `cut` and `step` values must be correctly set for
    //     this contract to return a valid price
    constructor() public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if      (what ==  "cut") require((cut = data) <= RAY, "StairstepExponentialDecrease/cut-gt-RAY");
        else if (what == "step") step = data;
        else revert("StairstepExponentialDecrease/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }
    // optimized version from dss PR #78
    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            // 0승이면 1(b는 1 * 정밀도)
            switch n case 0 { z := b }
            default {
                // 분모가 0이면 0으로 처리
                switch x case 0 { z := 0 }
                default {
                    // 분자가 짝수라면 1, 홀수라면 분모로 시작 
                    switch mod(n, 2) case 0 { z := b } default { z := x }
                    // 반올림을 위해 정밀도의 절반값 계산
                    let half := div(b, 2)  // for rounding.
                    // 분자 절반을 나눠가며 반복, 분자가 0이 되면 종료
                    for { n := div(n, 2) } n { n := div(n,2) } {
                        // 분모의 제곱
                        let xx := mul(x, x)
                        // 256bits가 최대이므로 128bits보다 큰 비트가 있다면 이미 overflow
                        if shr(128, x) { revert(0,0) }
                        // 분모의 제곱에 반올림(정밀하지 않음)
                        let xxRound := add(xx, half)
                        // 절반을 더했는데 원래 값보다 작을 경우 overflow
                        if lt(xxRound, xx) { revert(0,0) }
                        // 정밀도로 나누어서 정밀하지 않은 반올림에서 필요없는 부분 제거 (분모의 제곱 + 정밀도의 절반)
                        x := div(xxRound, b)
                        // 현재 n이 홀수일 때만 실행
                        if mod(n,2) {
                            // 현재 결과 * 갱신된 x(for문 시작부에서 나머지가 생기지않도록)
                            let zx := mul(z, x)
                            // 곱셈 결과가 유효하지않으면 실패
                            // x는 0이 아니여야하고, zx = x * z여야함
                            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                            // zx에 반올림
                            let zxRound := add(zx, half)
                            // overflow 확인
                            if lt(zxRound, zx) { revert(0,0) }
                            // 반올림에서 정밀하지않은 부분 제거
                            z := div(zxRound, b)
                        }
                    }
                }
            }
        }
    }

    // top: initial price
    // dur: seconds since the auction has started
    // step: seconds between a price drop
    // cut: cut encodes the percentage to decrease per step.
    //   For efficiency, the values is set as (1 - (% value / 100)) * RAY
    //   So, for a 1% decrease per step, cut would be (1 - 0.01) * RAY
    //
    // returns: top * (cut ^ dur)
    //
    //
    /**
     * @notice  .
     * @dev     .
     * @param   top  .
     * @param   dur  .
     * @return  uint256  .
     */
    function price(uint256 top, uint256 dur) override external view returns (uint256) {
        // dur / step = 지난시간 / 구간 = 가격감소 구간이 몇번 지났는지
        // cut ^ (dur / step) = 가격감소비율 ^ 가격감소 구간 횟수
        // rmul(top, rpow(cut, dur / step, RAY) = 현재 가격
        return rmul(top, rpow(cut, dur / step, RAY));
    }
}

// While an equivalent function can be obtained by setting step = 1 in StairstepExponentialDecrease,
// this continous (i.e. per-second) exponential decrease has be implemented as it is more gas-efficient
// than using the stairstep version with step = 1 (primarily due to 1 fewer SLOAD per price calculation).
contract ExponentialDecrease is Abacus {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "ExponentialDecrease/not-authorized");
        _;
    }

    // --- Data ---
    uint256 public cut;  // Per-second multiplicative factor [ray]

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    event File(bytes32 indexed what, uint256 data);

    // --- Init ---
    // @notice: `cut` value must be correctly set for
    //     this contract to return a valid price
    constructor() public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if      (what ==  "cut") require((cut = data) <= RAY, "ExponentialDecrease/cut-gt-RAY");
        else revert("ExponentialDecrease/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }
    // optimized version from dss PR #78
    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            // 분자가 0이면 1
            switch n case 0 { z := b }
            default {
                // 분모가 0이면 0
                switch x case 0 { z := 0 }
                default {
                    // 분자가 짝수면 1 홀수면 분모값
                    switch mod(n, 2) case 0 { z := b } default { z := x }
                    // 반올림용 정밀도의 절반값
                    let half := div(b, 2)
                    // 분자 절반씩 나누기
                    for { n := div(n, 2) } n { n := div(n,2) } {
                        // 분모 제곱
                        let xx := mul(x, x)
                        // overflow 확인
                        if shr(128, x) { revert(0,0) }
                        // 제곱한 분모에 반올림
                        let xxRound := add(xx, half)
                        // overflow 확인
                        if lt(xxRound, xx) { revert(0,0) }
                        x := div(xxRound, b)
                        if mod(n,2) {
                            let zx := mul(z, x)
                            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                            let zxRound := add(zx, half)
                            if lt(zxRound, zx) { revert(0,0) }
                            z := div(zxRound, b)
                        }
                    }
                }
            }
        }
    }

    // top: initial price
    // dur: seconds since the auction has started
    // cut: cut encodes the percentage to decrease per second.
    //   For efficiency, the values is set as (1 - (% value / 100)) * RAY
    //   So, for a 1% decrease per second, cut would be (1 - 0.01) * RAY
    //
    // returns: top * (cut ^ dur)
    //
    function price(uint256 top, uint256 dur) override external view returns (uint256) {
        // step으로 나누는 대신 지난 시간을 그대로 분자로 곱한다
        return rmul(top, rpow(cut, dur, RAY));
    }
}
