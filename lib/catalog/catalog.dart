import '../data/records.dart';

/// A ready product with a fixed price (price list).
class Product {
  final String id;
  final String name;
  final String material;
  final String materialId;
  final double grams;
  final double hours;
  final double cost; // cost price per piece when added
  final double price; // selling price per piece
  final String? thumbPath;

  /// Photo of the real printed product (shown instead of the render).
  final String? photoPath;

  const Product({
    required this.id,
    required this.name,
    required this.material,
    required this.materialId,
    required this.grams,
    required this.hours,
    required this.cost,
    required this.price,
    this.thumbPath,
    this.photoPath,
  });

  /// Best picture: the photo, else the render.
  String? get picture => photoPath ?? thumbPath;

  Product copyWith({String? name, double? price, String? photoPath, bool clearPhoto = false}) => Product(
        id: id,
        name: name ?? this.name,
        material: material,
        materialId: materialId,
        grams: grams,
        hours: hours,
        cost: cost,
        price: price ?? this.price,
        thumbPath: thumbPath,
        photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'material': material,
        'materialId': materialId,
        'grams': grams,
        'hours': hours,
        'cost': cost,
        'price': price,
        'thumbPath': thumbPath,
        'photoPath': photoPath,
      };

  static Product? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0.0;
    return Product(
      id: raw['id'] as String,
      name: raw['name'] is String ? raw['name'] as String : 'виріб',
      material: raw['material'] is String ? raw['material'] as String : '',
      materialId: raw['materialId'] is String ? raw['materialId'] as String : 'PLA',
      grams: d('grams'),
      hours: d('hours'),
      cost: d('cost'),
      price: d('price'),
      thumbPath: raw['thumbPath'] is String ? raw['thumbPath'] as String : null,
      photoPath: raw['photoPath'] is String ? raw['photoPath'] as String : null,
    );
  }
}

const productStore = RecordStore<Product>('catalog.json', Product.fromJson, _productJson, _productId);
Map<String, dynamic> _productJson(Product p) => p.toJson();
String _productId(Product p) => p.id;
