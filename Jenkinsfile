// Jenkinsfile — oh-my-dsh macOS 打包 + 上传 GitHub Release。
//
// 需要：macOS (Apple Silicon) Jenkins agent，安装：
//   - Xcode Command Line Tools（swiftc / codesign / iconutil / lipo / pkgbuild / hdiutil）
//   - curl / python3（构建 + 发布兜底）
//   - gh CLI（可选；无 gh 时发布走 curl API）
// 凭据：Jenkins Credentials 里配置 GitHub token（string），ID = github-release-token。
//
// 缓存：同一 agent 的 workspace .cache/ 会在各次构建间保留 —— build-cef.sh 的
// CEF tarball + 编译产物缓存、build-app.sh 的 node/runtime 缓存都落在 .cache/，
// 复用后构建显著变快（CEF 编译从几分钟降到 ~18s）。
pipeline {
  agent { label 'macos-arm64' }
  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 150, unit: 'MINUTES')
  }
  parameters {
    choice(name: 'DSH_ARCH', choices: ['arm64', 'x86_64', 'universal'], description: '目标架构（universal = lipo 双架构）')
    booleanParam(name: 'PUBLISH_RELEASE', defaultValue: false, description: '构建打包后发布到 GitHub Release')
    booleanParam(name: 'IS_PRERELEASE', defaultValue: true, description: '发布为预发布（仅 PUBLISH_RELEASE 时生效）')
    string(name: 'DSH_CEF_VERSION', defaultValue: '', description: '可选：覆盖 CEF 版本（留空用 build-cef.sh 默认）')
  }
  environment {
    DSH_ARCH = "${params.DSH_ARCH}"
    IS_PRERELEASE = "${params.IS_PRERELEASE ? '1' : '0'}"
  }
  stages {
    stage('Checkout + tags') {
      steps {
        checkout scm
        // version.sh 读 git tag；确保 tags 存在（Jenkins 默认浅克隆可能没有）
        sh 'git fetch --tags --force 2>/dev/null || true'
      }
    }
    stage('Build app') {
      steps {
        script {
          if (params.DSH_CEF_VERSION?.trim()) { env.DSH_CEF_VERSION = params.DSH_CEF_VERSION }
        }
        sh './platforms/macos/build-app.sh'
      }
    }
    stage('Package .pkg + .dmg') {
      steps {
        sh './platforms/macos/make-pkg.sh'
      }
    }
    stage('Publish GitHub Release') {
      when { expression { params.PUBLISH_RELEASE } }
      steps {
        script {
          env.RELEASE_VERSION = sh(script: 'scripts/version.sh | head -1', returnStdout: true).trim()
          echo "Releasing v${env.RELEASE_VERSION} (${params.DSH_ARCH})"
        }
        withCredentials([string(credentialsId: 'github-release-token', variable: 'GH_TOKEN')]) {
          sh 'chmod +x scripts/release-checksums.sh scripts/github-publish.sh'
          sh 'scripts/github-publish.sh "${RELEASE_VERSION}"'
        }
      }
    }
  }
  post {
    failure {
      echo 'Build or release failed — check the log above.'
    }
    always {
      // 保留产物供下载/归档
      archiveArtifacts artifacts: 'dist/oh-my-dsh-*', allowEmptyArchive: true
    }
  }
}
