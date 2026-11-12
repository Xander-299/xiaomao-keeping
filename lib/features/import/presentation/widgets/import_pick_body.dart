part of '../import_page.dart';

// ────────────────────────────── 第 1 步：选文件 ──────────────────────────────

class _PickBody extends StatelessWidget {
  const _PickBody({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Tok.rXl),
              boxShadow: p.hard(),
            ),
            child: ToonDashedBorder(
              radius: Tok.rXl,
              thickness: 3,
              color: p.ink,
              dash: 9,
              gap: 6,
              background: p.brandTint,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
                child: Column(
                  children: <Widget>[
                    Icon(
                      Icons.description_outlined,
                      size: 38,
                      color: p.brandDeep,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '选择微信 / 支付宝账单文件',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '微信：微信支付账单流水文件（.xlsx，ZIP 解压后解析）\n'
                      '支付宝：支付宝交易明细（.csv，GBK 编码自动识别）\n'
                      '小耄记账：自己导出的备份（.json，整本恢复）或流水（.csv）',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: p.ink2,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ToonButton(
                      icon: Icons.folder_open_rounded,
                      label: '选择文件',
                      small: true,
                      onPressed: onPick,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '导入规则',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '· 二次导入同一文件 → 0 新增（指纹幂等，PRD ADR-7）\n'
                '· 退款 / 不计收支行自动跳过\n'
                '· 关键词规则自动归类，未命中落「其他」\n'
                '· 金额按整数分入库，交易单号按字符串保留',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                  height: 1.9,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
