"""Package only an existing device build. Never represents a signed/installable IPA."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
app = root / 'build/DerivedData/Build/Products/Release-iphoneos/BridgeTalk.app'
if not (app / 'BridgeTalk').is_file() or not (app / 'Info.plist').is_file():
    raise SystemExit('缺少真实设备编译产物，不能生成 IPA。请先成功执行 xcodebuild。')
destination = root / 'build/BridgeTalk-UNSIGNED.ipa'
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as bundle:
    for file in sorted(app.rglob('*')):
        if file.is_file():
            bundle.write(file, 'Payload/BridgeTalk.app/' + file.relative_to(app).as_posix())
with zipfile.ZipFile(destination) as bundle:
    if bundle.testzip() is not None:
        raise SystemExit('IPA 压缩校验失败。')
print('已打包未签名产物：build/BridgeTalk-UNSIGNED.ipa；尚不能直接安装。')
