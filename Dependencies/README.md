# 第三方依赖来源

`SOURCES.json` 记录第三方源码和构建脚本的固定修订、来源与 SHA-256；`ADDITIONAL-SOURCES.json` 记录原站发布的源码包。源码归档在对应 Release 的 `ThirdPartySources.tar` 附件中。

播放器二进制依赖的原始地址和校验值见 `Vendor/MPVKit-Package.upstream.swift`。下载依赖可运行 `python3 Scripts/bootstrap.py`，也可以解压 Release 的 `Dependencies.zip`。

重新收集源码（需要 Python 3.11+、curl 和已登录的 GitHub CLI）：

```sh
python3 Scripts/collect_third_party_sources.py
python3 Scripts/collect_libdovi_crates.py
```

第二个脚本根据 libdovi 的 Cargo.lock 获取 Rust 依赖源码并校验；原站的非 GitHub 源码按 `ADDITIONAL-SOURCES.json` 中的地址获取。各组件许可证保留在各自源码归档中。部分构建工具的上游分支没有发布固定标签，清单记录本次归档解析出的提交，未声称它是上游构建时的工具提交。
