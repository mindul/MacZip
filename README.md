# Maczip

윈도우에서 **한글 파일명이 깨지지 않는 zip**을 만들고, 선택적으로 **비밀번호(ZipCrypto)** 를 거는 맥용 압축 앱입니다. 윈도우에서 만든 zip을 풀 때는 파일명 인코딩(UTF-8/CP949)을 자동으로 판별합니다.

## 다운로드

**[Maczip.dmg 내려받기 (최신 버전)](https://github.com/mindul/Maczip/releases/latest/download/Maczip.dmg)** · [릴리스 목록](https://github.com/mindul/Maczip/releases)

- macOS 14 이상, Apple Silicon·Intel 모두 지원
- dmg를 열고 Maczip을 Applications 폴더로 끌어다 놓으세요.
- 서명하지 않은 앱이라 처음 실행할 때 경고가 뜹니다. **Maczip을 우클릭 → 열기 → 열기**로 한 번만 허용하면 됩니다.

- 설계: `docs/superpowers/specs/2026-11-23-maczip-design.md`
- 구현 계획: `docs/superpowers/plans/2026-11-23-maczip.md`

## 사용법

- 파일·폴더를 창에 끌어다 놓거나, **창을 클릭해 파일 선택 창에서 여러 개를 골라** → **압축**.
  - 비밀번호는 두 번 입력합니다(두 칸이 같아야 압축 가능). 둘 다 비워 두면 암호 없이 만듭니다.
  - 비밀번호에는 영문·숫자·기호만 쓸 수 있습니다. 비밀번호 칸을 누르면 한글 자판이 영문으로 자동 전환되고, 칸을 벗어나면 원래 자판으로 돌아옵니다.
  - 결과: 첫 항목과 같은 폴더에 `이름.zip`(여러 개면 `archive.zip`). 같은 이름이 있으면 `archive 2.zip`처럼 번호를 붙입니다.
- `.zip` 파일 하나를 끌어다 놓기 → **압축 풀기**. 암호가 걸려 있으면 비밀번호를 묻습니다.
  - 결과: zip과 같은 폴더의 `zip이름/` 폴더.

## 빌드·검사

Xcode 없이 Command Line Tools만으로 동작합니다.

```bash
swift build                          # 디버그 빌드
swift run MaczipApp                  # 앱 바로 실행
swift run MaczipChecks               # 전체 검사 (XCTest 대신 자체 러너)
swift run MaczipChecks ZipReader     # 이름에 ZipReader가 든 검사만
swift run MaczipChecks ZipReader ZipWriter --big   # 400MB 메모리 검사 포함(느림)
```

## 설치 파일 만들기

```bash
./scripts/make-app.sh    # build/Maczip.app (Apple Silicon + Intel 유니버설)
./scripts/make-dmg.sh    # build/Maczip.dmg (앱 + Applications 바로가기 + 처음-여는-방법.txt)
```

서명·공증을 하지 않은 dmg입니다. 다른 맥에서 처음 열 때는 "확인되지 않은 개발자" 경고가 뜨므로 **우클릭 → 열기**로 한 번 허용해야 합니다(dmg 안의 `처음-여는-방법.txt` 참고).

## 알려진 한계

- 비밀번호는 **ZipCrypto**(암호 강도 약함). AES로 암호화된 zip은 풀지 못합니다.
- zip만 지원합니다. 7z, rar 등은 지원하지 않습니다.
- **4GB 이상**(ZIP64) 파일은 지원하지 않습니다.
- 심볼릭 링크는 압축·해제 모두 건너뜁니다.

## 수동 확인 목록

자동 검사로 확인할 수 없는 부분입니다.

### 맥에서 (앱 동작)

- [ ] 파일 하나 → 끌어다 놓기 → "압축하기: 1개 항목" 표시 → [압축] → `파일이름.zip` 생성, [Finder에서 보기] 동작
- [ ] 창 클릭 → 파일 선택 창에서 파일과 폴더를 여러 개 선택 → `archive.zip` 생성
- [ ] 한글 자판 상태에서 압축 비밀번호 칸 클릭 → 메뉴 막대의 입력 소스가 ABC로 바뀜 → 칸을 벗어나면 한글로 돌아옴
- [ ] 비밀번호 칸에 한글 입력 시도 → 입력되지 않고 "영문·숫자·기호만" 안내 표시
- [ ] 비밀번호 두 칸을 다르게 입력 → "비밀번호가 서로 다릅니다." 표시, [압축] 비활성
- [ ] 폴더 + 비밀번호(두 칸 같게) → ZipCrypto 경고 문구 표시 → 압축 완료
- [ ] 위에서 만든 비밀번호 zip 끌어다 놓기 → 비밀번호 시트 → 틀린 비밀번호 입력 시 "비밀번호가 맞지 않습니다." → 올바른 비밀번호로 해제
- [ ] 큰 폴더 압축 중 [취소] → 만들다 만 zip이 남지 않음
- [ ] 압축이 진행되는 동안 창이 멈추지 않고 진행 막대가 움직임

### 윈도우에서 (인수 기준)

윈도우 PC 또는 VM에서 Maczip이 만든 zip을 열어 봅니다.

- [ ] 한글 파일명·폴더명이 든 **평문 zip**을 **파일 탐색기**로 열기 → 이름이 깨지지 않음
- [ ] 같은 zip을 **반디집**(또는 7-Zip)으로 열기 → 이름이 깨지지 않음
- [ ] **영문·숫자 비밀번호** zip을 탐색기로 풀기 → 비밀번호 입력 후 정상 해제
- [ ] 같은 비밀번호 zip을 반디집으로 풀기 → 정상 해제
- [ ] `.DS_Store`, `__MACOSX` 같은 불필요한 파일이 zip 안에 보이지 않음
- [ ] 윈도우에서 한글 이름으로 만든 zip을 맥으로 가져와 Maczip으로 풀기 → 이름이 깨지지 않음
