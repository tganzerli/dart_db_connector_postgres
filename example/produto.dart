/// Sample entity used by the repository example and PoC.
class Produto {
  final int id;
  final String codigoBarras;
  final String descricao;
  final double precoUnitario;

  const Produto(
    this.id,
    this.codigoBarras,
    this.descricao,
    this.precoUnitario,
  );

  @override
  String toString() =>
      'Produto($id, $codigoBarras, "$descricao", \$$precoUnitario)';
}
