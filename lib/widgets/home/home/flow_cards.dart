import "package:auto_size_text/auto_size_text.dart";
import "package:flow/data/exchange_rates.dart";
import "package:flow/data/money.dart";
import "package:flow/data/money_flow.dart";
import "package:flow/entity/transaction.dart";
import "package:flow/l10n/named_enum.dart";
import "package:flow/objectbox/actions.dart";
import "package:flow/prefs.dart";
import "package:flow/theme/theme.dart";
import "package:flow/widgets/home/home/info_card.dart";
import "package:flutter/cupertino.dart";

class FlowCards extends StatefulWidget {
  final List<Transaction>? transactions;
  final ExchangeRates? rates;

  const FlowCards({super.key, required this.transactions, required this.rates});

  @override
  State<FlowCards> createState() => _FlowCardsState();
}

class _FlowCardsState extends State<FlowCards> {
  final AutoSizeGroup autoSizeGroup = AutoSizeGroup();

  @override
  Widget build(BuildContext context) {
    final MoneyFlow? flow = widget.transactions?.flow;
    final String primaryCurrency = LocalPreferences().getPrimaryCurrency();

    final Money? totalExpense = switch ((flow, widget.rates)) {
      (null, _) => null,
      (MoneyFlow moneyFlow, null) =>
        moneyFlow.getExpenseByCurrency(primaryCurrency),
      (MoneyFlow moneyFlow, ExchangeRates exchangeRates) =>
        moneyFlow.getTotalExpense(exchangeRates, primaryCurrency),
    };

    final Money? totalIncome = switch ((flow, widget.rates)) {
      (null, _) => null,
      (MoneyFlow moneyFlow, null) =>
        moneyFlow.getIncomeByCurrency(primaryCurrency),
      (MoneyFlow moneyFlow, ExchangeRates exchangeRates) =>
        moneyFlow.getTotalIncome(exchangeRates, primaryCurrency),
    };

    return Row(
      children: [
        Expanded(
          child: InfoCard(
            title: TransactionType.income.localizedNameContext(context),
            money: totalIncome,
            trailing: Icon(
              TransactionType.income.icon,
              color: TransactionType.income.color(context),
            ),
            autoSizeGroup: autoSizeGroup,
          ),
        ),
        const SizedBox(width: 16.0),
        Expanded(
          child: InfoCard(
            title: TransactionType.expense.localizedNameContext(context),
            money: totalExpense,
            trailing: Icon(
              TransactionType.expense.icon,
              color: TransactionType.expense.color(context),
            ),
            autoSizeGroup: autoSizeGroup,
          ),
        ),
      ],
    );
  }
}
