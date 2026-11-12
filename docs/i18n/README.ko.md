<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="../../assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**휴대폰으로 에이전트 지휘하기**

<a href="../../README.md">English</a> · <a href="../../docs/i18n/README.zh-CN.md">简体中文</a> · <a href="../../docs/i18n/README.zh-TW.md">繁體中文</a> · <a href="../../docs/i18n/README.ja.md">日本語</a> · <strong>한국어</strong> · <a href="../../docs/i18n/README.es.md">Español</a> · <a href="../../docs/i18n/README.fr.md">Français</a> · <a href="../../docs/i18n/README.de.md">Deutsch</a> · <a href="../../docs/i18n/README.pt-BR.md">Português (Brasil)</a>

</div>

이 프로젝트는 [dog.codes PC 앱](https://github.com/owlfy-ai/dogcodes)의 iOS / Android용 모바일 동반 앱이며, 사용하려면 PC 앱이 필요합니다.

내 컴퓨터에 연결해 대화를 이어 가고, 권한을 승인하고, 변경 사항을 검토하고, 프로젝트를 실행하고, 원격 데스크톱을 사용할 수 있습니다. 에이전트는 기존 계정과 구독으로 컴퓨터에서 실행됩니다.

[dog.codes](https://dog.codes) · [데스크톱 앱](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.ko.md) · [기능](#phone) · [개발 가이드](../../docs/development.md)

## PC에서 지원하는 에이전트

이미 사용 중인 에이전트를 연결하세요. 아래 12개 연동이 구현되어 있습니다. 모델, 승인, 사용량 정보, 복구 기능은 에이전트와 설치 버전에 따라 다릅니다. 먼저 각 에이전트의 공식 도구로 설치하고 로그인하세요.

<p align="center">
  <a href="https://developers.openai.com/codex/"><img src="../../docs/images/readme/agents/codex.png" alt="Codex" height="36" /></a>
  <a href="https://code.claude.com/docs/en/overview"><img src="../../docs/images/readme/agents/claude-code.png" alt="Claude Code" height="36" /></a>
  <a href="https://cursor.com/"><img src="../../docs/images/readme/agents/cursor.png" alt="Cursor" height="36" /></a>
  <a href="https://www.kimi.com/"><img src="../../docs/images/readme/agents/kimi.png" alt="Kimi Code" height="36" /></a>
  <a href="https://grok.com/"><img src="../../docs/images/readme/agents/grok.png" alt="Grok Build" height="36" /></a>
  <a href="https://z.ai/"><img src="../../docs/images/readme/agents/zcode.png" alt="ZCode" height="36" /></a>
  <br />
  <a href="https://antigravity.google/"><img src="../../docs/images/readme/agents/antigravity.png" alt="Antigravity" height="36" /></a>
  <a href="https://www.codebuddy.ai/"><img src="../../docs/images/readme/agents/codebuddy.png" alt="CodeBuddy" height="36" /></a>
  <a href="https://pi.dev/"><img src="../../docs/images/readme/agents/pi.png" alt="Pi" height="36" /></a>
  <a href="https://opencode.ai/"><img src="../../docs/images/readme/agents/opencode.png" alt="OpenCode" height="36" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="../../docs/images/readme/agents/deepseek-harness.png" alt="DeepSeek Harness" height="36" /></a>
  <a href="https://kiro.dev/"><img src="../../docs/images/readme/agents/kiro.png" alt="Kiro" height="36" /></a>
</p>

<a id="phone"></a>

## 휴대폰으로 에이전트 지휘하기

**노트북은 집에 두고 가세요. 에이전트는 컴퓨터에서 계속 일하고, 지휘권은 휴대폰이 쥡니다.**

휴대폰을 한 번만 페어링하면 아래의 모든 것을 어디서든 할 수 있습니다. 코드와 에이전트는 계속 내 컴퓨터에 남아 있습니다.

![휴대폰으로 에이전트 지휘하기](../../docs/images/readme/en/phone-remote.png)

- **대화를 이어 가거나 새로 시작.** 컴퓨터의 어떤 대화든 열어 이어 가거나 새 세션을 시작하세요. 에이전트, 모델, 사고 강도를 고르고, 출력이 실시간으로 흐르는 모습을 보며, 세션을 검색·고정·보관·분기할 수 있습니다.

  ![대화를 이어 가거나 새로 시작.](../../docs/images/readme/en/switch-agent.png)

- **승인하고 답하기.** 권한 요청과 에이전트의 질문이 푸시 알림과 함께 휴대폰으로 도착하고, 한 번 탭하면 에이전트가 계속 진행합니다. 모든 승인은 컴퓨터의 원래 실행과 대조해 확인됩니다.

  ![승인하고 답하기.](../../docs/images/readme/en/permissions.png)

- **검토하고 커밋.** 모든 프로젝트 폴더의 변경 사항을 보고, 파일을 스테이징하고, 에이전트에게 커밋 메시지를 쓰게 한 뒤 커밋·푸시·풀·동기화하세요. 커밋 기록을 열람하고 브랜치를 읽기 전용으로 비교할 수도 있습니다. 한 턴의 파일 변경을 한 번에 되돌릴 수도 있습니다.

  ![검토하고 커밋.](../../docs/images/readme/en/git-changes.png)

- **PC 폴더로 프로젝트 추가.** 컴퓨터의 폴더를 둘러보고 하나를 프로젝트로 추가하세요. 책상에 다시 앉을 필요가 없습니다.

  ![PC 폴더로 프로젝트 추가.](../../docs/images/readme/en/add-project.png)

- **PC 터미널에서 명령 실행.** 어떤 프로젝트 폴더에서든 터미널을 열고 컴퓨터의 진짜 셸에서 작업하세요.

  ![PC 터미널에서 명령 실행.](../../docs/images/readme/en/terminal.png)

- **프로젝트를 실행하고 휴대폰으로 확인.** 컴퓨터에서 실행 항목을 시작하고, 실행 중인 웹 앱을 휴대폰에서 바로 여세요.

  ![프로젝트를 실행하고 휴대폰으로 확인.](../../docs/images/readme/en/run-project.png)

- **파일 열람과 첨부.** 프로젝트 파일을 읽고, 메시지에 파일과 이미지를 첨부할 수 있습니다.

  ![파일 열람과 첨부.](../../docs/images/readme/en/files-attachments.png)

- **필요할 땐 원격 데스크톱.** 컴퓨터 화면을 보면서 탭, 드래그, 스크롤, 핀치, 입력, 텍스트·이미지 붙여넣기를 할 수 있으며, 화질은 네트워크 상태에 맞춰 조정됩니다.

![필요할 땐 원격 데스크톱.](../../docs/images/readme/en/remote-desktop.png)

### 연결 방식

- QR 코드를 한 번 스캔하면 되며 계정은 필요 없습니다. 연결은 종단 간 암호화됩니다. 컴퓨터를 여러 대 페어링하고, 접속 상태를 확인하고, 데스크톱 앱에서 언제든 휴대폰 연결을 해제할 수 있습니다.
- 휴대폰은 가능하면 직접 연결하고, 그렇지 않으면 암호화된 트래픽만 전달하는 dog.codes 중계 서비스를 거칩니다.
- 컴퓨터는 켜 둔 채 dog.codes를 열어 두거나 최소화해 두세요. 작업이나 원격 세션이 진행 중일 때는 dog.codes가 컴퓨터의 자동 절전을 막을 수 있으며, 이 옵션은 끌 수 있습니다.
- 원격 데스크톱은 macOS, Windows, Linux(X11 및 Wayland) 컴퓨터를 지원하며, 필요한 화면·입력 권한은 운영 체제가 요청합니다.

<a id="getting-started"></a>

## 시작하기

1. 컴퓨터에 [dog.codes 데스크톱 앱](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.ko.md)을 설정하고, 지원 에이전트를 하나 이상 설치해 로그인한 뒤 프로젝트 폴더를 추가하세요.
2. dog.codes를 열어 두거나 최소화하고 「Connect phone」을 연 뒤, 휴대폰의 「Connect computer」에서 QR 코드를 스캔하세요.
3. 컴퓨터와 프로젝트를 선택하고 대화를 이어 가거나 새로 시작하세요.

아직 컴퓨터가 없다면 첫 화면에서 **먼저 예시 둘러보기**를 눌러 가상의 컴퓨터로 앱을 체험해 보세요. 아무것에도 연결하지 않습니다.

휴대폰 UI는 11개 언어를 지원합니다: 한국어, 영어, 중국어 간체·번체, 일본어, 프랑스어, 독일어, 스페인어, 브라질 포르투갈어, 러시아어, 이탈리아어. 소스 빌드, 로컬 페어링, 테스트 및 구현 설명은 [개발 가이드](../../docs/development.md)를 참고하세요.

에이전트 아이콘은 데스크톱 앱과 공유합니다. [소재 출처 및 고지](../../docs/images/readme/agents/README.md)를 참고하세요. 제품 이름과 상표는 각 소유자에게 귀속됩니다.
