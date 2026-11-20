import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { HarmonyBridge } from '../common/HarmonyBridge';

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: HarmonyBridge = new HarmonyBridge();
  private uiContext: UIContext = this.getUIContext();

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.bridge.attach(this.controller, context);
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE'])
      .catch((err: Object) => console.error(`ABandOn microphone permission failed: ${JSON.stringify(err)}`));
  }

  aboutToDisappear(): void {
    try {
      this.controller.deleteJavaScriptRegister('abandonHost');
    } catch (_) {}
  }

  build() {
    Column() {
      Web({ src: $rawfile('index.html'), controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .domStorageAccess(true)
        .onPermissionRequest((event) => {
          if (event) event.request.grant(event.request.getAccessibleResource());
        })
        .javaScriptProxy({
          object: this.bridge,
          name: 'abandonHost',
          methodList: ['dispatch'],
          controller: this.controller
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161b26')
  }
}
