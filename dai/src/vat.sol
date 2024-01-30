// SPDX-License-Identifier: AGPL-3.0-or-later

/// vat.sol -- Dai CDP database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
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

// FIXME: This contract was altered compared to the production version.
// It doesn't use LibNote anymore.
// New deployments of this contract will need to include custom events (TO DO).

contract Vat {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 1; }
    function deny(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Vat/not-authorized");
        _;
    }

    mapping(address => mapping (address => uint)) public can;
    function hope(address usr) external { can[msg.sender][usr] = 1; }
    function nope(address usr) external { can[msg.sender][usr] = 0; }
    function wish(address bit, address usr) internal view returns (bool) {
        // mapping으로 전송 가능 여부를 참으로 설정해둬야 성공
        return either(bit == usr, can[bit][usr] == 1);
    }

    // --- Data ---
    struct Ilk {
        uint256 Art;   // 정규화된 총 빚             [wad]
        uint256 rate;  // 누적되는 고정 수수료                [ray]
        uint256 spot;  // 안전 마진을 포함한 가격     [ray]
        uint256 line;  // 특정 토큰으로 빌릴 수 있는 최대 DAI의 양    [rad]
        uint256 dust;  // 특정 vault에서 빚 최소 한도         [rad]
    }
    struct Urn {
        uint256 ink;   // 묶여 있는 담보의 양  [wad]
        uint256 art;   // 정규화된 빚(DAI의 양)    [wad]
    }

    mapping (bytes32 => Ilk)                       public ilks;
    mapping (bytes32 => mapping (address => Urn )) public urns;
    mapping (bytes32 => mapping (address => uint)) public gem;  // [wad]
    mapping (address => uint256)                   public dai;  // [rad]
    mapping (address => uint256)                   public sin;  // [rad]

    uint256 public debt;  // Total Dai Issued    [rad]
    uint256 public vice;  // Total Unbacked Dai  [rad]
    uint256 public Line;  // Total Debt Ceiling  [rad]
    uint256 public live;  // Active Flag

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        live = 1;
    }

    // --- Math ---
    function _add(uint x, int y) internal pure returns (uint z) {
        // solidity 0.8 이전에는 y가 음수일 경우 uint256으로 변환하면 큰 값으로 변환되어 
        // overflow를 이용하여 음수계산도 가능
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function _sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function _mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function _add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function _sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function _mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function init(bytes32 ilk) external auth {
        // ilk는 특정 collateral
        // rate는 DAI에 대해 쌓이는 수수료
        require(ilks[ilk].rate == 0, "Vat/ilk-already-init");
        ilks[ilk].rate = 10 ** 27;
    }
    /**
     * @dev     general setting
     * @param   what  general한 사항들 중 어떤 사항을 변경할 것인지
     * @param   data  수치를 어떻게 변경할 것인지
     */
    function file(bytes32 what, uint data) external auth {
        require(live == 1, "Vat/not-live");
        // 모든 종류의 토큰들이 생성할 수 있는 DAI의 최종 총량
        if (what == "Line") Line = data;
        else revert("Vat/file-unrecognized-param");
    }

    /**
     * @dev     특정 토큰에 대한 setting
     * @param   ilk  토큰 종류
     * @param   what  어떤 사항을 변경할 것인지
     * @param   data  수치를 어떻게 변경할 것인지
     */
    function file(bytes32 ilk, bytes32 what, uint data) external auth {
        require(live == 1, "Vat/not-live");
        if (what == "spot") ilks[ilk].spot = data;
        // 특정 토큰이 생성할 수 있는 DAI의 총량
        else if (what == "line") ilks[ilk].line = data;
        // 최소 DAI수
        else if (what == "dust") ilks[ilk].dust = data;
        else revert("Vat/file-unrecognized-param");
    }
    
    /**
     * @dev     vault 중지
     */
    function cage() external auth {
        live = 0;
    }

    // --- Fungibility ---
    /**
     * @dev     일반적인 ERC20의 mint와 유사
     * @param   ilk  .
     * @param   usr  .
     * @param   wad  .
     */
    function slip(bytes32 ilk, address usr, int256 wad) external auth {
        // gem은 collteral 토큰
        // 콜레트럴 토큰 mint
        gem[ilk][usr] = _add(gem[ilk][usr], wad);
    }

    /**
     * @dev     일반적인 ERC20의 transfer과 유사
     * @param   ilk  token address
     * @param   src  from
     * @param   dst  to
     * @param   wad  amount
     */
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external {
        require(wish(src, msg.sender), "Vat/not-allowed");
        gem[ilk][src] = _sub(gem[ilk][src], wad);
        gem[ilk][dst] = _add(gem[ilk][dst], wad);
    }
    
    /**
     * @dev     DAI의 transfer과 유사
     * @param   src  from
     * @param   dst  to
     * @param   rad  amount
     */
    function move(address src, address dst, uint256 rad) external {
        require(wish(src, msg.sender), "Vat/not-allowed");
        dai[src] = _sub(dai[src], rad);
        dai[dst] = _add(dai[dst], rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    /**
     * @dev     담보 <-> DAI로 변환하는 행동을 할 때 사용하는 메서드
     * @param   i  collteral token 종류
     * @param   u  vault 소유자 주소
     * @param   v  토큰을 담보로 vault에서 무언가를 하려는 주소
     * @param   w  DAI토큰을 받는 주소
     * @param   dink  colletral amount
     * @param   dart  DAI amount
     */
    function frob(bytes32 i, address u, address v, address w, int dink, int dart) external {
        // system is live
        require(live == 1, "Vat/not-live");

        // 토큰 vault 가져오기
        Urn memory urn = urns[i][u];
        Ilk memory ilk = ilks[i];
        // ilk has been initialised
        require(ilk.rate != 0, "Vat/ilk-not-init");

        // 해당 토큰이 vault의 묶여있는 양 추가(담보)
        urn.ink = _add(urn.ink, dink);
        // 해당 토큰 vault의 생성된 DAI의 양 추가
        urn.art = _add(urn.art, dart);
        // 토큰 vault 세부 데이터(ilk)들 중 DAI의 양 추가
        ilk.Art = _add(ilk.Art, dart);

        // 추가하려는 빚의 크기 = 고정 수수료율 * 생성하려는 DAI 양
        int dtab = _mul(ilk.rate, dart);
        // 갚아야 할 빚의 총 크기 = 누적 고정 수수료율 * 해당 토큰으로 생성된 DAI totalSupply
        uint tab = _mul(ilk.rate, urn.art);
        // 모든 vault의 생성된 DAI totalSupply에 (누적 고정 수수료율 * 생성하려는 DAI 양) 더하기
        debt     = _add(debt, dtab);

        // either debt has decreased, or debt ceilings are not exceeded
        // DAI를 꺼내는 경우 || (토큰 vault의 DAI totalSupply * 고정 수수료율 <= 가능한 최대 DAI의 양 && 모든 vault의 DAI의 양 <= 모든 vault에서 가능한 최대 DAI의 양)
        require(either(dart <= 0, both(_mul(ilk.Art, ilk.rate) <= ilk.line, debt <= Line)), "Vat/ceiling-exceeded");
        // urn is either less risky than before, or it is safe
        // 빚을 갚는 경우(DAI -> token) || 갚아야할 빚의 총 크기 <= 담보 * 안전 마진을 포함한 가격(과담보된 상태를 유지하고 있는지)
        require(either(both(dart <= 0, dink >= 0), tab <= _mul(urn.ink, ilk.spot)), "Vat/not-safe");

        // urn is either more safe, or the owner consents
        // 빚을 갚는 경우(DAI -> token) || msg.sender가 특정 토큰 vault를 조작하는 것이 허용되어있는지
        require(either(both(dart <= 0, dink >= 0), wish(u, msg.sender)), "Vat/not-allowed-u");
        // collateral src consents
        // 담보가 감소하는 상황(담보를 써서 무언가를 하는 상황) || msg.sender가 담보 주인에 대해 무언가 행동하는 것을 허락받았는지
        require(either(dink <= 0, wish(v, msg.sender)), "Vat/not-allowed-v");
        // 빚이 감소하는 상황(DAI를 써서 무언가를 하는 상황) || msg.sender가 DAI를 받을 주소(주인)에게 대해 무언가 행동하는 것이 허락받았는지
        require(either(dart >= 0, wish(w, msg.sender)), "Vat/not-allowed-w");

        // urn has no debt, or a non-dusty amount
        // 담보가 0 || 갚아야할 DAI의 총 크기가 가능한 DAI의 최소 크기보다 큰지
        require(either(urn.art == 0, tab >= ilk.dust), "Vat/dust");

        // 해당 토큰 vault의 보유 토큰 감소(담보로 사용)
        gem[i][v] = _sub(gem[i][v], dink);
        // DAI 추가(담보로 DAI 대출)
        dai[w]    = _add(dai[w],    dtab);

        // 해당 토큰에 대한 vault 내용 업데이트  
        urns[i][u] = urn;
        ilks[i]    = ilk;
    }
    
    // --- CDP Fungibility ---
    /**
     * @dev     from에서 to로 담보나 DAI를 이동시키는 메서드
     * @param   ilk  담보로 사용할 토큰
     * @param   src  from
     * @param   dst  to
     * @param   dink  담보
     * @param   dart  DAI
     */
    function fork(bytes32 ilk, address src, address dst, int dink, int dart) external {
        // 해당 토큰에 대한 각 유저의 담보량, DAI량 가져오기
        Urn storage u = urns[ilk][src];
        Urn storage v = urns[ilk][dst];
        // 해당 토큰의 세부 데이터 가져오기
        Ilk storage i = ilks[ilk];

        // from에서 담보와 DAI를 꺼내서
        u.ink = _sub(u.ink, dink);
        u.art = _sub(u.art, dart);
        // to로 전송
        v.ink = _add(v.ink, dink);
        v.art = _add(v.art, dart);

        // 각 유저가 갚아야 할 빚의 총 크기 계산
        uint utab = _mul(u.art, i.rate);
        uint vtab = _mul(v.art, i.rate);

        // both sides consent
        // from과 to에게서 조작하는 것을 허용받았는지 체크
        require(both(wish(src, msg.sender), wish(dst, msg.sender)), "Vat/not-allowed");

        // both sides safe
        // 옮긴 이후 담보의 가치가 빚보다 큰지 체크
        require(utab <= _mul(u.ink, i.spot), "Vat/not-safe-src");
        require(vtab <= _mul(v.ink, i.spot), "Vat/not-safe-dst");

        // both sides non-dusty
        // 옮긴 이후 빚이 DAI 최소 크기보다 큰지 확인  
        require(either(utab >= i.dust, u.art == 0), "Vat/dust-src");
        require(either(vtab >= i.dust, v.art == 0), "Vat/dust-dst");
    }
    
    // --- CDP Confiscation ---
    /**
     * @dev     강제 청산
     * @param   i  collteral token 종류
     * @param   u  vault의 소유자 주소
     * @param   v  토큰을 담보로 vault에서 무언가를 하려는 주소
     * @param   w  DAI토큰을 받는 주소
     * @param   dink  담보 amount
     * @param   dart  DAI amount
     */
    function grab(bytes32 i, address u, address v, address w, int dink, int dart) external auth {
        // 해당 토큰에 대한 vault 주인의 담보, DAI의 크기 데이터 
        Urn storage urn = urns[i][u];
        // 해당 토큰에 대한 세부 데이터
        Ilk storage ilk = ilks[i];

        // vault 담보량 추가
        urn.ink = _add(urn.ink, dink);
        // vault DAI양 추가
        urn.art = _add(urn.art, dart);
        // 해당 토큰 담보량 추가
        ilk.Art = _add(ilk.Art, dart);
        // 추가하려는 빚의 크기 계산(청산 크기)
        int dtab = _mul(ilk.rate, dart);

        // v가 보유하고 있는 담보 토큰 감소 
        gem[i][v] = _sub(gem[i][v], dink);
        // 청산한 크기만큼 DAI토큰을 받는 주소의 시스템 부채 감소
        sin[w]    = _sub(sin[w],    dtab);
        // 청산한 크기만큼 전체 시스템 부채 감소
        vice      = _sub(vice,      dtab);
    }

    // --- Settlement ---
    /**
     * @dev     DAI를 태워 유저의 시스템 부채를 갚는 메서드
     * @param   rad  태울 양
     */
    function heal(uint rad) external {
        address u = msg.sender;
        // DAI를 태워 유저의 시스템 부채 감소
        sin[u] = _sub(sin[u], rad);
        dai[u] = _sub(dai[u], rad);
        // 전체 시스템 부채도 감소 처리
        vice   = _sub(vice,   rad);
        // DAI를 태웠으니 전체 DAI totalSupply 감소
        debt   = _sub(debt,   rad);
    }
    
    /**
     * @dev     u의 시스템 부채를 늘려서 v의 DAI를 늘리는 메서드
     * @param   u  시스템 부채가 늘어날 주소
     * @param   v  DAI가 증가할 주소
     * @param   rad  amount
     */
    function suck(address u, address v, uint rad) external auth {
        // u의 시스템 부채를 늘려서
        sin[u] = _add(sin[u], rad);
        // v의 DAI를 증가시킨다
        dai[v] = _add(dai[v], rad);
        // 전체 시스템 부채도 같이 증가하고
        vice   = _add(vice,   rad);
        // 전체 DAI totalSupply도 증가한다
        debt   = _add(debt,   rad);
    }

    // --- Rates ---
    /**
     * @dev     고정 수수료율 조정
     * @param   i  토큰의 종류
     * @param   u  조정한 고정 수수료율 만큼 DAI를 받거나 뺏길 주소
     * @param   rate  조정할 고정 수수료율
     */
    function fold(bytes32 i, address u, int rate) external auth {
        require(live == 1, "Vat/not-live");
        // 토큰에 대한 세부 데이터 가져오기
        Ilk storage ilk = ilks[i];
        // 누적 고정 수수료율에 인수 rate만큼 조정
        ilk.rate = _add(ilk.rate, rate);
        // 해당 토큰에 대한 증감된 빚 계산
        int rad  = _mul(ilk.Art, rate);
        // 증감된 빚만큼 u주소의 DAI를 변경 
        dai[u]   = _add(dai[u], rad);
        // DAI totalSupply 변경
        debt     = _add(debt,   rad);
    }
}
