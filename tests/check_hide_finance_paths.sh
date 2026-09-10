#!/bin/sh
set -eu

entry_file="$(dirname "$0")/../PortEntry.m"

echo "[1/5] Checking hide-finance storage key and switch fallback..."
grep -Fq 'static NSString * const AntForestHideFinanceKey = @"antforest_hideFinance";' "$entry_file"
grep -Fq 'static BOOL hideFinanceEnabled(void);' "$entry_file"
grep -Fq 'return [[NSUserDefaults standardUserDefaults] boolForKey:AntForestHideFinanceKey];' "$entry_file"

echo "[2/5] Checking finance tab removal and restore path..."
grep -Fq 'static UITabBarController *findTabBarVC(UIViewController *vc)' "$entry_file"
grep -Fq 'static UITabBarController *rootTabBarVC(void)' "$entry_file"
grep -Fq 'static void removeFinanceTabsFromTBC(UITabBarController *tbc)' "$entry_file"
grep -Fq 'static void restoreFinanceTabsFromTBC(UITabBarController *tbc)' "$entry_file"
grep -Fq 'static void refreshTabBarFinance(void)' "$entry_file"
grep -Fq 'if ([((UIViewController *)controllers[i]).tabBarItem.title isEqualToString:@"理财"]) { financeIndex = i; break; }' "$entry_file"
grep -Fq 'if ([((UIViewController *)controllers[i]).tabBarItem.title isEqualToString:@"消息"]) { insertIndex = i; break; }' "$entry_file"
grep -Fq '[tbc setViewControllers:remaining animated:NO];' "$entry_file"
grep -Fq 'if (tbc.selectedIndex >= financeIndex) tbc.selectedIndex = tbc.selectedIndex - 1;' "$entry_file"
grep -Fq 'if (tbc.selectedIndex >= insertIndex) tbc.selectedIndex = tbc.selectedIndex + 1;' "$entry_file"

echo "[3/5] Checking first-layout hook and foreground fallback..."
grep -Fq 'static void (*originalTabBarLayoutSubviews)(UITabBar *self, SEL _cmd);' "$entry_file"
grep -Fq 'static void portTabBarLayoutSubviews(UITabBar *self, SEL _cmd) {' "$entry_file"
grep -Fq 'hookMethod(tabBarClass, @selector(layoutSubviews), (IMP)portTabBarLayoutSubviews, (IMP *)&originalTabBarLayoutSubviews);' "$entry_file"
grep -Fq 'if (hideFinanceEnabled()) removeFinanceTab();' "$entry_file"
grep -Fq 'refreshTabBarFinance();' "$entry_file"

echo "[4/5] Checking settings panel row is wired last..."
grep -Fq 'UIButton *hideFinance = [self settingsButtonWithTitle:@"隐藏理财" detail:@"隐藏支付宝底栏理财" icon:@"eye.slash.fill" action:nil];' "$entry_file"
grep -Fq 'hideFinanceSwitch.on = hideFinanceEnabled();' "$entry_file"
grep -Fq '[hideFinanceSwitch addTarget:self action:@selector(toggleHideFinance:) forControlEvents:UIControlEventValueChanged];' "$entry_file"
grep -Fq '[contentView addSubview:patrolNew]; [contentView addSubview:hideFinance];' "$entry_file"
grep -Fq '[hideFinance.topAnchor constraintEqualToAnchor:patrolNew.bottomAnchor constant:12]' "$entry_file"
grep -Fq '[hideFinance.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-24],' "$entry_file"
grep -Fq -- '- (void)toggleHideFinance:(UISwitch *)sender { [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:AntForestHideFinanceKey]; refreshTabBarFinance();' "$entry_file"

echo "[5/5] Checking abandoned transform approach stayed out..."
if grep -Fq 'applyHideFinance' "$entry_file"; then exit 1; fi
if grep -Fq 'applyFinanceToView' "$entry_file"; then exit 1; fi
if grep -Fq 'gFinanceApplying' "$entry_file"; then exit 1; fi
if grep -Fq 'bar.transform = CGAffineTransformIdentity' "$entry_file"; then exit 1; fi

echo "✅ All hide-finance path checks passed successfully!"
