# check-ec2-monitor

EC2インスタンスとEBSボリュームの状態を確認するスクリプトです。

## 前提条件

- AWS CLI がインストールされていること
- `jq` コマンドがインストールされていること
- AWS認証情報が設定されていること

## AWS認証設定（IIC一時クレデンシャル）

Identity Center (IIC) の一時クレデンシャルを使用して認証します。

```bash
# AWS CLIの設定（初回のみ）
aws configure sso

# プロファイル情報を入力
# SSO start URL: https://your-organization.awsapps.com/start
# SSO region: ap-northeast-1
# アカウントとロールを選択
# プロファイル名を設定

# 一時クレデンシャルの取得
aws sso login --profile your-profile-name

# 環境変数に設定（推奨）
export AWS_PROFILE=your-profile-name
```

## 使い方

```bash
# 実行権限の付与
chmod +x ec2_ebs_check.sh

# 基本的な使い方
./ec2_ebs_check.sh <instance-id>

# リージョンを指定する場合
./ec2_ebs_check.sh <instance-id> <region>

# 実行例
./ec2_ebs_check.sh i-1234567890abcdef0 ap-northeast-1
```

## 取得できる情報

- EC2インスタンスの状態・スペック情報
- EBSボリュームの詳細（サイズ、タイプ、IOPS）
- CPU使用率（過去1時間）
- ネットワークトラフィック
- EBS I/Oメトリクス
- インスタンスステータスチェック
- アクティブなCloudWatchアラーム