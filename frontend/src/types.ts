export type ProductVariant = {
  id: string
  sku: string
  price_override: number | null
  in_stock: boolean
  size: { id: number; label: string } | null
  color: { id: number; name_ar: string; name_en: string | null; hex: string } | null
}

export type ProductImage = {
  id: string
  path: string
  alt_ar: string | null
  is_primary: boolean
  sort_order: number
}

export type Product = {
  id: string
  slug: string
  name_ar: string
  name_en: string | null
  description_ar: string | null
  description_en: string | null
  gender: 'men' | 'women' | 'unisex'
  base_price: number
  compare_at_price: number | null
  discount_percent: number | null
  is_featured: boolean
  created_at: string
  category: { slug: string; name_ar: string; name_en: string | null } | null
  variants: ProductVariant[]
  images: ProductImage[]
}

export type CartLine = {
  variantId: string
  quantity: number
  product: Product
  variant: ProductVariant
}
