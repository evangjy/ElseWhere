import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { buffer } from '@kit.ArkTS';

type JsonMap = Record<string, Object>;

/**
 * Web ↔ ArkTS bridge used by the shared ABandOn Web UI.
 * The web page only knows the `abandonHost.dispatch(payload)` method, so the
 * same index.html can be embedded by iPadOS and HarmonyOS without a fork.
 */
export class HarmonyBridge {
  private controller: webview.WebviewController | undefined;
  private context: common.UIAbilityContext | undefined;
  private root: string = '';

  attach(controller: webview.WebviewController, context: common.UIAbilityContext): void {
    this.controller = controller;
    this.context = context;
    this.root = `${context.filesDir}/Library`;
    try {
      fileIo.mkdirSync(this.root, true);
    } catch (_) {}
  }

  /** Public proxy method. It intentionally accepts one JSON string. */
  dispatch(payload: string): void {
    try {
      const message = JSON.parse(payload) as JsonMap;
      const op = String(message['op'] ?? '');
      if (op === 'lib' || op === 'rec') {
        void this.handleRpc(message);
      } else if (op === 'open') {
        this.openPicker();
      } else if (op === 'save') {
        this.savePicker(String(message['name'] ?? 'score.gp'), String(message['data'] ?? ''));
      } else if (op === 'share') {
        this.savePicker(String(message['name'] ?? 'score.gp'), String(message['data'] ?? ''));
      }
    } catch (err) {
      console.error(`ABandOn bridge message failed: ${JSON.stringify(err)}`);
    }
  }

  private reply(cb: number, value: Object): void {
    if (!this.controller) return;
    const safe = JSON.stringify({ v: value });
    this.controller.runJavaScript({
      script: `window.libResult(${cb},${safe})`
    });
  }

  private pathOf(rel: string): string {
    const clean = rel.replace(/\\/g, '/');
    if (clean.split('/').some((part: string) => part === '..' || part === '.')) {
      throw new Error('路径无效');
    }
    return clean.length > 0 ? `${this.root}/${clean}` : this.root;
  }

  private parentOf(path: string): string {
    const i = path.lastIndexOf('/');
    return i > 0 ? path.slice(0, i) : this.root;
  }

  private cleanName(name: string): string {
    const clean = name.replace(/[\\/:]/g, '_').trim();
    if (!clean) throw new Error('名称不能为空');
    return clean;
  }

  private readBase64(path: string): string {
    const stat = fileIo.statSync(path);
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const raw = new ArrayBuffer(stat.size);
      const count = fileIo.readSync(f.fd, raw, { offset: 0, length: stat.size });
      return buffer.from(raw.slice(0, count)).toString('base64');
    } finally {
      fileIo.closeSync(f);
    }
  }

  private writeBase64(path: string, data: string): void {
    fileIo.mkdirSync(this.parentOf(path), true);
    const bytes = buffer.from(data, 'base64');
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(f.fd, bytes.buffer, { offset: 0, length: bytes.byteLength });
    } finally {
      fileIo.closeSync(f);
    }
  }

  private async list(rel: string): Promise<Object[]> {
    const path = this.pathOf(rel);
    const names = await fileIo.listFile(path);
    const out: Object[] = [];
    names.forEach((name: string) => {
      if (name.startsWith('.')) return;
      const child = `${path}/${name}`;
      const stat = fileIo.statSync(child);
      out.push({
        name,
        dir: stat.isDirectory(),
        size: stat.size,
        created: Number(stat.mtime) * 1000
      });
    });
    return out;
  }

  private async tree(rel: string, out: string[]): Promise<void> {
    const path = this.pathOf(rel);
    const names = await fileIo.listFile(path);
    for (const name of names) {
      if (name.startsWith('.')) continue;
      const child = rel ? `${rel}/${name}` : name;
      const stat = fileIo.statSync(`${this.root}/${child}`);
      if (stat.isDirectory()) {
        out.push(child);
        await this.tree(child, out);
      }
    }
  }

  private async handleRpc(message: JsonMap): Promise<void> {
    const cb = Number(message['cb'] ?? 0);
    const cmd = String(message['cmd'] ?? '');
    try {
      if (String(message['op'] ?? '') === 'rec') {
        this.reply(cb, { err: 'HarmonyOS 录音桥接尚未启用；谱面播放、编辑、PDF 与资料库功能可用。' });
        return;
      }
      const path = String(message['path'] ?? '');
      let value: Object = null;
      switch (cmd) {
        case 'list':
          value = await this.list(path);
          break;
        case 'tree': {
          const dirs: string[] = [''];
          await this.tree('', dirs);
          value = dirs.sort();
          break;
        }
        case 'read':
          value = this.readBase64(this.pathOf(path));
          break;
        case 'write':
          this.writeBase64(this.pathOf(path), String(message['data'] ?? ''));
          value = true;
          break;
        case 'import': {
          const name = this.cleanName(String(message['name'] ?? '未命名.gp'));
          const dir = String(message['dir'] ?? '');
          const folder = `${this.pathOf(dir)}/${name.replace(/\.[^.]+$/, '')}`;
          fileIo.mkdirSync(folder, true);
          const dest = `${folder}/${name}`;
          this.writeBase64(dest, String(message['data'] ?? ''));
          value = this.relative(dest);
          break;
        }
        case 'mkdir':
          fileIo.mkdirSync(this.pathOf(path), true);
          value = true;
          break;
        case 'rename': {
          const dest = `${this.parentOf(this.pathOf(path))}/${this.cleanName(String(message['newName'] ?? ''))}`;
          fileIo.renameSync(this.pathOf(path), dest);
          value = true;
          break;
        }
        case 'move': {
          const source = this.pathOf(path);
          const dest = `${this.pathOf(String(message['dest'] ?? ''))}/${source.slice(source.lastIndexOf('/') + 1)}`;
          fileIo.renameSync(source, dest);
          value = true;
          break;
        }
        case 'delete': {
          const target = this.pathOf(path);
          const stat = fileIo.statSync(target);
          if (stat.isDirectory()) fileIo.rmdirSync(target, true);
          else fileIo.unlinkSync(target);
          value = true;
          break;
        }
        default:
          value = { err: '未知命令' };
      }
      this.reply(cb, value);
    } catch (err) {
      this.reply(cb, { err: String(err) });
    }
  }

  private relative(path: string): string {
    return path.startsWith(`${this.root}/`) ? path.slice(this.root.length + 1) : '';
  }

  private openPicker(): void {
    if (!this.context) return;
    const options = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FILE;
    options.fileSuffixFilters = ['.gp', '.gp3', '.gp4', '.gp5', '.gpx', '.pdf', '.musicxml', '.xml', '.mxl', '.mscz', '.mscx'];
    new picker.DocumentViewPicker(this.context).select(options).then((uris: string[]) => {
      if (!uris.length || !this.controller) return;
      const uri = uris[0];
      const name = decodeURIComponent(uri.split('/').pop() ?? 'score.gp');
      const data = this.readBase64(uri);
      const n = JSON.stringify(name);
      const b = JSON.stringify(data);
      this.controller.runJavaScript({ script: `window.onOpen(${n},${b})` });
    }).catch((err: Object) => console.error(`ABandOn picker failed: ${JSON.stringify(err)}`));
  }

  private savePicker(name: string, data: string): void {
    if (!this.context) return;
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [this.cleanName(name)];
    new picker.DocumentViewPicker(this.context).save(options).then((uris: string[]) => {
      if (uris.length) this.writeBase64(uris[0], data);
    }).catch((err: Object) => console.error(`ABandOn save failed: ${JSON.stringify(err)}`));
  }
}
