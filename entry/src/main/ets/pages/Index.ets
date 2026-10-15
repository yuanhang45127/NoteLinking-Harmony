// NoteLink WebView 壳：加载 notelink 站点，首启引导输入访问令牌（存本地偏好并注入
// localStorage['nl-token']），返回键映射网页历史，文件选择走系统 DocumentViewPicker，
// 麦克风权限桥接给网页（语音速记）。站点本身已是响应式 Web 应用，壳保持最薄。
import { webview } from '@kit.ArkWeb';
import { picker } from '@kit.CoreFileKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const BASE_URL = 'https://notelink.obsidianlyh.top';
const PREFS_NAME = 'notelink_shell';
const TOKEN_KEY = 'site_token';
// 令牌不预填在源码里（本仓库公开）：首次启动弹窗输入一次，存本地偏好

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State token: string = '';
  @State tokenReady: boolean = false;      // 偏好里读完令牌
  @State showTokenDialog: boolean = false;
  @State tokenInput: string = '';
  @State loadFailed: boolean = false;      // 主文档加载失败（离线/服务不可达）
  @State progress: number = 0;
  @State showProgress: boolean = false;

  aboutToAppear(): void {
    this.loadToken();
  }

  async loadToken(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const store = await preferences.getPreferences(ctx, PREFS_NAME);
      const saved = (await store.get(TOKEN_KEY, '')) as string;
      this.token = saved;
    } catch {
      this.token = '';
    }
    this.showTokenDialog = this.token === '';
    this.tokenReady = true;
  }

  async saveToken(): Promise<void> {
    const t = this.tokenInput.trim();
    if (!t) {
      return;
    }
    this.token = t;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const store = await preferences.getPreferences(ctx, PREFS_NAME);
      await store.put(TOKEN_KEY, t);
      await store.flush();
    } catch {
      // 存不进偏好就只在本次会话生效
    }
    this.loadFailed = false;
    this.showTokenDialog = false;
  }

  buildInjectScripts(): Array<ScriptItem> {
    // 令牌只可能是受限字符，仍做一次白名单清洗防注入；空令牌不注入，
    // 以免覆盖站点自身登录入口存下的值
    const safe = this.token.replace(/[^A-Za-z0-9_-]/g, '');
    if (!safe) {
      return [];
    }
    return [
      {
        script: `(function(){try{localStorage.setItem('nl-token','${safe}');}catch(e){}})();`,
        scriptRules: ['https://*.obsidianlyh.top/*']
      }
    ];
  }

  onBackPress(): boolean {
    if (this.controller.accessBackward()) {
      this.controller.backward();
      return true;
    }
    return false;
  }

  build() {
    Stack() {
      if (this.tokenReady) {
        Web({ src: BASE_URL, controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)          // 站点把令牌与会话状态放 localStorage
          .databaseAccess(true)
          .zoomAccess(true)
          .fileAccess(true)
          .javaScriptOnDocumentStart(this.buildInjectScripts())
          .onProgressChange((event: OnProgressChangeEvent) => {
            this.progress = event.newProgress;
            this.showProgress = this.progress < 100;
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            // 只处理主文档错误；子资源偶发失败不打扰
            if (event.request.isMainFrame()) {
              this.loadFailed = true;
            }
          })
          .onShowFileSelector((event: OnShowFileSelectorEvent): boolean => {
            this.pickFiles(event);
            return true;
          })
          .onPermissionRequest((event: OnPermissionRequestEvent) => {
            this.grantPermission(event);
          })
      } else {
        Column() {
          LoadingProgress().width(42).height(42).color('#5b7cfa')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }

      if (this.showProgress && !this.loadFailed && this.tokenReady) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%').height(2)
      }

      if (this.loadFailed && this.tokenReady) {
        this.ErrorView()
      }

      if (this.showTokenDialog) {
        this.TokenDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f6f7fb')
  }

  @Builder
  ErrorView() {
    Column({ space: 14 }) {
      Text('连接不上 NoteLink').fontSize(18).fontWeight(FontWeight.Bold)
      Text('检查网络后重试；若令牌已更换可修改访问令牌。')
        .fontSize(13).opacity(0.6).textAlign(TextAlign.Center)
      Button('重试')
        .onClick(() => {
          this.loadFailed = false;
          this.controller.refresh();
        })
      Button('修改访问令牌')
        .backgroundColor('#e8eaf6').fontColor('#3949ab')
        .onClick(() => {
          this.tokenInput = this.token;
          this.showTokenDialog = true;
        })
    }.width('80%').justifyContent(FlexAlign.Center)
  }

  @Builder
  TokenDialog() {
    Column({ space: 12 }) {
      Text('访问令牌').fontSize(17).fontWeight(FontWeight.Bold)
      Text('NoteLink 站点访问令牌，首次使用输入一次即可（之后自动记住）。')
        .fontSize(12.5).opacity(0.6)
      TextInput({ text: this.tokenInput })
        .type(InputType.Password)
        .width('100%')
        .onChange((v: string) => {
          this.tokenInput = v;
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor('#eceff1').fontColor('#546e7a')
          .onClick(() => {
            this.showTokenDialog = false;
          })
        Button('保存')
          .layoutWeight(1)
          .onClick(() => {
            this.saveToken();
          })
      }.width('100%').margin({ top: 4 })
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor(Color.White)
    .width('84%')
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 6 })
  }

  /** 网页文件选择（PDF 导入、图片等）→ 系统文档选择器 */
  pickFiles(event: OnShowFileSelectorEvent): void {
    const options = new picker.DocumentSelectOptions();
    const multiple = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
    options.maxSelectNumber = multiple ? 9 : 1;
    const suffixes = event.fileSelector.getAcceptType()
      .filter((a: string): boolean => a.startsWith('.'));
    if (suffixes.length > 0) {
      options.fileSuffixFilters = suffixes;
    }
    const docPicker = new picker.DocumentViewPicker();
    docPicker.select(options)
      .then((uris: Array<string>) => {
        event.result.handleFileList(uris || []);
      })
      .catch(() => {
        event.result.handleFileList([]);
      });
  }

  /** 网页申请受限资源（麦克风：语音速记）→ 应用内授权后放行给 WebView */
  grantPermission(event: OnPermissionRequestEvent): void {
    const resources = event.request.getAccessibleResource();
    const ctx = getContext(this) as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE'])
      .then((res) => {
        const granted = res.authResults.length > 0 && res.authResults.every((r: number): boolean => r === 0);
        if (granted) {
          event.request.grant(resources);
        } else {
          event.request.deny();
        }
      })
      .catch(() => {
        event.request.deny();
      });
  }
}
