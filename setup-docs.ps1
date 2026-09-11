<#
  setup-docs.ps1 —— 一键重建三个项目到共享文档仓的 Junction 链接

  用途：Junction 是文件系统特性，不进 git。新机器 / 新克隆后运行本脚本即可恢复。
  用法：powershell -ExecutionPolicy Bypass -File setup-docs.ps1
  注意：mklink /J 不需要管理员权限。

  链接布局：
    web   : <web>\docs        -> teyvat-docs\web
            <web>\shared-docs -> teyvat-docs\shared
    admin : <admin>\docs      -> teyvat-docs\admin
            <admin>\aidoc     -> teyvat-docs\ai
            <admin>\shared-docs -> teyvat-docs\shared
    ai    : <ai>\doc          -> teyvat-docs\ai
            <ai>\shared-docs  -> teyvat-docs\shared
#>

$ErrorActionPreference = 'Stop'

# 共享文档仓（本脚本所在目录）
$Docs = $PSScriptRoot

# 三个项目的本地路径（按需修改）
$WebProj   = 'C:\Users\HONOR\Desktop\AI提瓦特向导'
$AdminProj = 'C:\Users\HONOR\Desktop\demo_in_windows\demo-app'
$AiProj    = 'C:\Users\HONOR\Desktop\AI派蒙服务器\ai-service'

$links = @(
    @{ Project = $WebProj;   Name = 'docs';        Target = Join-Path $Docs 'web' },
    @{ Project = $WebProj;   Name = 'shared-docs'; Target = Join-Path $Docs 'shared' },
    @{ Project = $AdminProj; Name = 'docs';        Target = Join-Path $Docs 'admin' },
    @{ Project = $AdminProj; Name = 'aidoc';       Target = Join-Path $Docs 'ai' },
    @{ Project = $AdminProj; Name = 'shared-docs'; Target = Join-Path $Docs 'shared' },
    @{ Project = $AiProj;    Name = 'doc';         Target = Join-Path $Docs 'ai' },
    @{ Project = $AiProj;    Name = 'shared-docs'; Target = Join-Path $Docs 'shared' }
)

foreach ($l in $links) {
    if (-not (Test-Path $l.Project)) {
        Write-Host "[跳过] 项目不存在: $($l.Project)" -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path $l.Target)) {
        Write-Host "[跳过] 目标目录不存在: $($l.Target)" -ForegroundColor Yellow
        continue
    }

    $linkPath = Join-Path $l.Project $l.Name
    if (Test-Path $linkPath) {
        $item = Get-Item $linkPath -Force
        if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
            # 已是指向本仓的链接：重建以刷新目标
            cmd /c rmdir "$linkPath" | Out-Null
        }
        else {
            Write-Host "[冲突] $linkPath 是真实目录（非链接），请先自行确认其内容去向，已跳过" -ForegroundColor Red
            continue
        }
    }

    cmd /c mklink /J "$linkPath" "$($l.Target)" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] $linkPath -> $($l.Target)" -ForegroundColor Green
    }
    else {
        Write-Host "[失败] $linkPath -> $($l.Target)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '完成。验证：在任一项目内读取 docs/ 与 shared-docs/ 应看到共享仓内容；' -ForegroundColor Cyan
Write-Host '且 git status 不应把这两个目录当作项目改动（已加入各项目 .gitignore）。' -ForegroundColor Cyan
