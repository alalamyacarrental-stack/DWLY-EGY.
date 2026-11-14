import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ArrowLeft, ArrowUpLeft, Check, ChevronDown, LoaderCircle, LogIn,
  Menu, Minus, Plus, Search, ShoppingBag, SlidersHorizontal, UserRound, X,
} from 'lucide-react'
import { isSupabaseConfigured, productImageUrl, supabase } from './lib/supabase'
import type { CartLine, Product, ProductVariant } from './types'
import type { Session } from '@supabase/supabase-js'
import AdminDashboard from './AdminDashboard'

const CART_KEY = 'dwly_egy_guest_cart_v1'
type Page = 'home' | 'men' | 'women' | 'shoes' | 'account' | 'admin'
type GuestLine = { variantId: string; quantity: number }

function money(value: number) {
  return new Intl.NumberFormat('ar-EG', { maximumFractionDigits: 2 }).format(value) + ' ج.م'
}

function readGuestCart(): GuestLine[] {
  try {
    const value = JSON.parse(localStorage.getItem(CART_KEY) || '[]') as GuestLine[]
    return Array.isArray(value) ? value.filter(x => x && typeof x.variantId === 'string' && Number.isInteger(x.quantity) && x.quantity > 0 && x.quantity <= 20) : []
  } catch { return [] }
}

export default function App() {
  const [page, setPage] = useState<Page>('home')
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const [products, setProducts] = useState<Product[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState('')
  const [session, setSession] = useState<Session | null>(null)
  const [authReady, setAuthReady] = useState(false)
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState('newest')
  const [selectedProduct, setSelectedProduct] = useState<Product | null>(null)
  const [selectedVariant, setSelectedVariant] = useState<ProductVariant | null>(null)
  const [cartOpen, setCartOpen] = useState(false)
  const [cartLines, setCartLines] = useState<CartLine[]>([])
  const [guestLines, setGuestLines] = useState<GuestLine[]>(readGuestCart)
  const [notice, setNotice] = useState('')
  const [authMode, setAuthMode] = useState<'signin' | 'signup'>('signin')
  const [authBusy, setAuthBusy] = useState(false)
  const [authError, setAuthError] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [checkoutOpen, setCheckoutOpen] = useState(false)
  const [orderConfirmation, setOrderConfirmation] = useState<{ order_number: string; total: number } | null>(null)

  const loadProducts = useCallback(async () => {
    if (!supabase) { setProducts([]); setLoadError(''); setLoading(false); return }
    setLoading(true); setLoadError('')
    const { data, error } = await supabase.from('products').select(`
      id,slug,name_ar,name_en,description_ar,description_en,gender,base_price,compare_at_price,discount_percent,is_featured,created_at,
      category:categories(slug,name_ar,name_en),
      variants:product_variants!inner(id,sku,price_override,is_active,size:sizes(id,label),color:colors(id,name_ar,name_en,hex)),
      images:product_images(id,path,alt_ar,is_primary,sort_order)
    `).eq('status', 'active').eq('is_demo', false).eq('variants.is_active', true)
      .order('created_at', { ascending: false })
    if (error) { setLoadError('تعذر تحميل المنتجات من قاعدة البيانات. راجع إعدادات Supabase وصلاحيات RLS.'); setProducts([]) }
    else {
      const normalized = (data || []).map((raw: any) => ({
        ...raw,
        category: Array.isArray(raw.category) ? raw.category[0] ?? null : raw.category,
        variants: (raw.variants || []).map((v: any) => ({
          ...v,
          size: Array.isArray(v.size) ? v.size[0] ?? null : v.size,
          color: Array.isArray(v.color) ? v.color[0] ?? null : v.color,
        })),
        images: (raw.images || []).sort((a: any, b: any) => Number(b.is_primary) - Number(a.is_primary) || a.sort_order - b.sort_order),
      })) as Product[]
      const productIds = normalized.map(product => product.id)
      if (productIds.length) {
        // variant_stock is the boolean-only, RLS-enforced projection from migration 0011.
        // It exposes in_stock only, never inventory.quantity. Fail closed on read errors.
        const { data: stockRows, error: stockError } = await supabase.from('variant_stock')
          .select('variant_id,product_id,in_stock').in('product_id', productIds)
        if (stockError) {
          setLoadError('تعذر التحقق من توافر المقاسات والمخزون. لم نعرض المنتجات حتى لا نظهر حالة مخزون غير مؤكدة.')
          setProducts([]); setLoading(false); return
        }
        const stockByVariant = new Map((stockRows || []).map((row: { variant_id: string; in_stock: boolean }) => [row.variant_id, row.in_stock]))
        for (const product of normalized) for (const variant of product.variants) {
          // Missing inventory rows fail closed: a variant is never shown as available by default.
          variant.in_stock = stockByVariant.get(variant.id) === true
        }
      }
      setProducts(normalized)
    }
    setLoading(false)
  }, [])

  const refreshRemoteCart = useCallback(async (uid: string, catalog = products, silent = false) => {
    if (!supabase) return
    const { data: cart, error: cartError } = await supabase.from('carts').select('id').eq('user_id', uid).maybeSingle()
    if (cartError) { if (!silent) setNotice('تعذر التحقق من السلة المحفوظة. حاول تحديث الصفحة.'); return }
    if (!cart) { setCartLines([]); return }
    const { data, error } = await supabase.from('cart_items').select('variant_id,quantity').eq('cart_id', cart.id)
    if (error) { if (!silent) setNotice('تعذر قراءة السلة المحفوظة.'); return }
    const lines: CartLine[] = []
    for (const row of data || []) {
      for (const product of catalog) {
        const variant = product.variants.find(v => v.id === row.variant_id)
        if (variant) { lines.push({ variantId: variant.id, quantity: row.quantity, product, variant }); break }
      }
    }
    setCartLines(lines)
  }, [products])

  useEffect(() => { void loadProducts() }, [loadProducts])

  useEffect(() => {
    if (!supabase) { setAuthReady(true); return }
    let active = true
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      setSession(data.session); setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
    })
    return () => { active = false; listener.subscription.unsubscribe() }
  }, [])

  useEffect(() => {
    if (!session?.user || products.length === 0) return
    let active = true
    const sync = async () => {
      if (!supabase) return
      const pending = readGuestCart()
      let allSynced = true
      for (const line of pending) {
        const { error } = await supabase.rpc('cart_set_item', { p_variant_id: line.variantId, p_quantity: line.quantity })
        if (error) { allSynced = false; setNotice('تم تسجيل الدخول، لكن تعذرت مزامنة بعض عناصر سلة الزائر. ما زالت محفوظة على هذا الجهاز.'); break }
      }
      if (pending.length && allSynced) { localStorage.removeItem(CART_KEY); setGuestLines([]) }
      if (active) await refreshRemoteCart(session.user.id, products)
    }
    void sync()
    return () => { active = false }
  }, [session?.user.id, products, refreshRemoteCart])

  useEffect(() => {
    if (!session) localStorage.setItem(CART_KEY, JSON.stringify(guestLines))
  }, [guestLines, session])

  const filteredProducts = useMemo(() => {
    let list = [...products]
    if (page === 'men') list = list.filter(p => p.gender === 'men' || p.gender === 'unisex')
    if (page === 'women') list = list.filter(p => p.gender === 'women' || p.gender === 'unisex')
    if (page === 'shoes') list = list.filter(p => p.category?.slug === 'shoes' || /shoe|sneaker|حذاء|أحذية/i.test(`${p.category?.name_ar || ''} ${p.category?.name_en || ''}`))
    const term = query.trim().toLocaleLowerCase('ar')
    if (term) list = list.filter(p => `${p.name_ar} ${p.name_en || ''} ${p.category?.name_ar || ''}`.toLocaleLowerCase('ar').includes(term))
    if (sort === 'price-asc') list.sort((a, b) => a.base_price - b.base_price)
    if (sort === 'price-desc') list.sort((a, b) => b.base_price - a.base_price)
    if (sort === 'featured') list.sort((a, b) => Number(b.is_featured) - Number(a.is_featured))
    return list
  }, [products, page, query, sort])

  const count = session ? cartLines.reduce((n, x) => n + x.quantity, 0) : guestLines.reduce((n, x) => n + x.quantity, 0)
  const subtotal = session ? cartLines.reduce((n, x) => n + Number(x.variant.price_override ?? x.product.base_price) * x.quantity, 0)
    : guestLines.reduce((n, x) => {
      const p = products.find(product => product.variants.some(v => v.id === x.variantId))
      const v = p?.variants.find(v => v.id === x.variantId)
      return n + (p && v ? Number(v.price_override ?? p.base_price) * x.quantity : 0)
    }, 0)

  const openProduct = useCallback((product: Product) => {
    setSelectedProduct(product)
    setSelectedVariant(product.variants[0] ?? null)
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }, [])

  const setNav = (next: Page) => { setMobileNavOpen(false); setPage(next); setSelectedProduct(null); setQuery(''); window.scrollTo({ top: 0, behavior: 'smooth' }) }

  const addToCart = async (variant: ProductVariant) => {
    // Adding an item is intentionally silent: no toast and no automatic cart popup.
    setNotice('')
    if (session && supabase) {
      const current = cartLines.find(x => x.variantId === variant.id)?.quantity || 0
      const { error } = await supabase.rpc('cart_set_item', { p_variant_id: variant.id, p_quantity: current + 1 })
      if (error) return
      await refreshRemoteCart(session.user.id, products, true)
    } else {
      setGuestLines(old => {
        const found = old.find(x => x.variantId === variant.id)
        return found ? old.map(x => x.variantId === variant.id ? { ...x, quantity: Math.min(20, x.quantity + 1) } : x)
          : [...old, { variantId: variant.id, quantity: 1 }]
      })
    }
  }

  const updateQuantity = async (line: CartLine, quantity: number) => {
    if (session && supabase) {
      const { error } = await supabase.rpc('cart_set_item', { p_variant_id: line.variantId, p_quantity: quantity })
      if (error) { setNotice('تعذر تحديث الكمية. تأكد من المخزون.'); return }
      await refreshRemoteCart(session.user.id)
    } else {
      setGuestLines(old => quantity <= 0 ? old.filter(x => x.variantId !== line.variantId)
        : old.map(x => x.variantId === line.variantId ? { ...x, quantity } : x))
    }
  }

  const submitAuth = async (event: React.FormEvent) => {
    event.preventDefault(); setAuthError('')
    if (!supabase) return
    setAuthBusy(true)
    const result = authMode === 'signin'
      ? await supabase.auth.signInWithPassword({ email: email.trim(), password })
      : await supabase.auth.signUp({ email: email.trim(), password, options: { data: { full_name: fullName.trim(), phone: phone.trim() } } })
    if (result.error) setAuthError(result.error.message)
    else if (authMode === 'signup' && !result.data.session) setAuthError('تم إنشاء الحساب. افتح رسالة تأكيد البريد الإلكتروني ثم سجّل الدخول.')
    else { setPage('home'); setNotice(authMode === 'signup' ? 'تم إنشاء الحساب بنجاح.' : 'أهلًا بعودتك.') }
    setAuthBusy(false)
  }

  const signOut = async () => { if (supabase) await supabase.auth.signOut(); setCartLines([]); setPage('home') }
  const startCheckout = () => {
    if (!session) { setCartOpen(false); setPage('account'); setNotice('سجّل الدخول أولًا لإتمام الطلب وحفظه في حسابك.'); return }
    if (!cartLines.length) { setNotice('السلة فارغة. أضف منتجات قبل إتمام الطلب.'); return }
    setCartOpen(false); setCheckoutOpen(true)
  }
  const checkoutSucceeded = async (order: { order_number: string; total: number }) => {
    setCheckoutOpen(false); setOrderConfirmation(order); setCartLines([]); setGuestLines([]);
    if (session?.user) await refreshRemoteCart(session.user.id);
    await loadProducts();
  }
  const title = page === 'men' ? 'قسم الرجال' : page === 'women' ? 'قسم النساء' : page === 'shoes' ? 'الأحذية' : 'اختار اللي شبهك'

  return <div className="app-shell">
    <div className="topline">توصيل القاهرة 60 ج.م · الجيزة 75 ج.م · الدفع عند الاستلام</div>
    <header className="site-header">
      <button className="icon-btn mobile-menu" aria-label="القائمة" onClick={() => setMobileNavOpen(value => !value) }><Menu size={21}/></button>
      <button className="wordmark" onClick={() => setNav('home')} aria-label="DWLY EGY الرئيسية"><span dir="ltr">dwly<span className="brand-dot">.</span>eg</span></button>
      <nav className="main-nav" aria-label="الأقسام">
        <button className={page === 'men' ? 'active' : ''} onClick={() => setNav('men')}>رجالي</button>
        <button className={page === 'women' ? 'active' : ''} onClick={() => setNav('women')}>حريمي</button>
        <button className={page === 'shoes' ? 'active' : ''} onClick={() => setNav('shoes')}>أحذية</button>
      </nav>
      {mobileNavOpen && <nav className="mobile-nav-panel" aria-label="أقسام المتجر"><button onClick={() => setNav('men')}>رجالي</button><button onClick={() => setNav('women')}>حريمي</button><button onClick={() => setNav('shoes')}>أحذية</button><button onClick={() => setNav('account')}>حسابي</button></nav>}
      <div className="header-actions">
        <button className="icon-btn account-action" aria-label="حسابي" onClick={() => setNav('account')}><UserRound size={20}/></button>
        {session && <button className="admin-entry" onClick={() => setNav('admin')}>الإدارة</button>}
        <button className="cart-action" onClick={() => setCartOpen(true)}><ShoppingBag size={18}/><span>السلة</span><b>{count}</b></button>
      </div>
    </header>

    {!isSupabaseConfigured && <div className="config-alert">اربط المشروع ببيانات Supabase في ملف <code>frontend/.env</code> لعرض الكتالوج الحقيقي.</div>}

    {selectedProduct ? <ProductDetail product={selectedProduct} selected={selectedVariant} onSelect={setSelectedVariant} onBack={() => setSelectedProduct(null)} onAdd={() => selectedVariant && void addToCart(selectedVariant)} /> : page === 'admin' ? <AdminDashboard session={session} onExit={() => setNav(session ? 'account' : 'home')} /> : page === 'account' ? <AccountPage session={session} authReady={authReady} authMode={authMode} setAuthMode={setAuthMode} email={email} setEmail={setEmail} password={password} setPassword={setPassword} fullName={fullName} setFullName={setFullName} phone={phone} setPhone={setPhone} busy={authBusy} error={authError} onSubmit={submitAuth} onSignOut={signOut} /> : <>
      {page === 'home' && <section className="hero">
        <div className="hero-copy"><span className="eyebrow">NEW SEASON · DWLY EGY</span><h1>هدومك اللي<br/><em>بتشبهك.</em></h1><p>ستايلك يبدأ من هنا. اكتشف قطع مختارة بتفاصيل بسيطة وشخصية واضحة.</p><button className="primary-btn" onClick={() => document.getElementById('catalog')?.scrollIntoView({ behavior: 'smooth' })}>اكتشف المجموعة <ArrowLeft size={17}/></button><div className="hero-meta"><span>01 / COLLECTION</span><span>MADE FOR YOUR EVERYDAY</span></div></div>
        <div className="hero-art" aria-label="مساحة صور الحملة"><div className="hero-orbit orbit-one"/><div className="hero-orbit orbit-two"/><div className="hero-caption"><span>DWLY</span><b>YOUR<br/>DAILY<br/>UNIFORM.</b></div><span className="hero-index">EGY — 2026</span></div>
      </section>}
      <main id="catalog" className="catalog-section">
        <div className="section-heading"><div><span className="eyebrow">THE DWLY EDIT</span><h2>{title}</h2><p>{page === 'home' ? 'قطع مختارة من الكتالوج المنشور.' : 'اكتشف المنتجات المتاحة في هذا القسم.'}</p></div><span className="result-count">{filteredProducts.length.toString().padStart(2, '0')} PRODUCTS</span></div>
        <div className="catalog-tools"><label className="search-box"><Search size={18}/><input value={query} onChange={e => setQuery(e.target.value)} placeholder="دوّر على منتج..." aria-label="ابحث عن منتج"/><kbd>⌕</kbd></label><label className="sort-box"><SlidersHorizontal size={16}/><span>ترتيب حسب</span><select value={sort} onChange={e => setSort(e.target.value)}><option value="newest">الأحدث</option><option value="featured">المميزة</option><option value="price-asc">السعر: الأقل</option><option value="price-desc">السعر: الأعلى</option></select><ChevronDown size={14}/></label></div>
        {!isSupabaseConfigured ? <div className="state-panel error-state">اتصال Supabase غير مُعد. لم نستخدم منتجات أو مخزونًا تجريبيًا بدلًا من البيانات الحقيقية.</div> : loading ? <div className="state-panel"><LoaderCircle className="spin"/> بنحمّل المنتجات من المتجر...</div> : loadError ? <div className="state-panel error-state">{loadError}<button onClick={() => void loadProducts()}>إعادة المحاولة</button></div> : filteredProducts.length === 0 ? <div className="empty-catalog"><div className="empty-mark">DWLY</div><h3>{products.length === 0 ? 'لسه مفيش منتجات منشورة' : 'مفيش نتائج للبحث ده'}</h3><p>{products.length === 0 ? 'لما تضيف منتجات حقيقية وتفعّل نشرها هتظهر هنا تلقائيًا.' : 'جرّب كلمة بحث تانية أو اختار قسم مختلف.'}</p>{query && <button className="text-btn" onClick={() => setQuery('')}>مسح البحث</button>}</div> : <div className="product-grid">{filteredProducts.map(product => <ProductCard key={product.id} product={product} onOpen={openProduct} />)}</div>}
      </main>
    </>}

    <footer className="site-footer"><div className="footer-brand"><span dir="ltr">dwly.eg</span><p>هدومك اللي بتشبهك.</p></div><div className="footer-links"><button onClick={() => setNav('men')}>رجالي</button><button onClick={() => setNav('women')}>حريمي</button><button onClick={() => setNav('shoes')}>أحذية</button><button onClick={() => setNav('account')}>حسابي</button></div><small>© 2026 DWLY EGY. جميع الحقوق محفوظة.</small><small className="developer-credit" dir="ltr">Developed by BOKA MOHAMED FADLE</small></footer>

    {cartOpen && <div className="overlay" onMouseDown={e => { if (e.target === e.currentTarget) setCartOpen(false) }}><aside className="cart-drawer"><div className="drawer-head"><div><span className="eyebrow">YOUR BAG</span><h2>سلة المشتريات <small>({count})</small></h2></div><button className="icon-btn" onClick={() => setCartOpen(false)} aria-label="إغلاق"><X/></button></div>
      {(session ? cartLines : guestLines.map(line => { const p = products.find(x => x.variants.some(v => v.id === line.variantId)); const v = p?.variants.find(x => x.id === line.variantId); return p && v ? { ...line, product: p, variant: v } : null }).filter(Boolean) as CartLine[]).length === 0 ? <div className="drawer-empty"><ShoppingBag size={35}/><p>السلة لسه فاضية</p><button className="primary-btn" onClick={() => setCartOpen(false)}>كمّل تسوق</button></div> : <>
      <div className="cart-lines">{(session ? cartLines : guestLines.map(line => { const p = products.find(x => x.variants.some(v => v.id === line.variantId)); const v = p?.variants.find(x => x.id === line.variantId); return p && v ? { ...line, product: p, variant: v } : null }).filter(Boolean) as CartLine[]).map(line => <div className="cart-line" key={line.variantId}><div className="cart-thumb">{line.product.images[0] && <img src={productImageUrl(line.product.images[0].path) || ''} alt="" loading="lazy" decoding="async" width={78} height={95} onError={e => { e.currentTarget.style.display = 'none' }}/>}</div><div className="cart-line-info"><b>{line.product.name_ar}</b><small>{line.variant.size?.label || 'مقاس موحد'} · {line.variant.color?.name_ar || 'لون'}</small><strong>{money(Number(line.variant.price_override ?? line.product.base_price))}</strong><div className="quantity-control"><button onClick={() => void updateQuantity(line, line.quantity - 1)} aria-label="تقليل"><Minus size={13}/></button><span>{line.quantity}</span><button onClick={() => void updateQuantity(line, Math.min(20, line.quantity + 1))} aria-label="زيادة"><Plus size={13}/></button></div></div><button className="remove-line" onClick={() => void updateQuantity(line, 0)} aria-label="حذف المنتج"><X size={16}/></button></div>)}</div>
      <div className="drawer-summary"><div><span>المجموع الفرعي</span><b>{money(subtotal)}</b></div><p>الشحن والخصومات يتم حسابهم في خطوة إتمام الطلب.</p><button className="primary-btn full-btn" onClick={startCheckout}>إتمام الطلب</button></div></>}
    </aside></div>}
    {checkoutOpen && session && <CheckoutPanel session={session} onClose={() => setCheckoutOpen(false)} onSuccess={checkoutSucceeded} />}
    {orderConfirmation && <div className="overlay"><section className="checkout-panel order-success"><div className="success-mark"><Check size={30}/></div><span className="eyebrow">ORDER CONFIRMED</span><h2>طلبك اتسجل بنجاح</h2><p>رقم الطلب</p><strong className="order-number">{orderConfirmation.order_number}</strong><h3>{money(orderConfirmation.total)}</h3><p>الدفع عند الاستلام. تقدر تتابع حالة الطلب من حسابك.</p><button className="primary-btn full-btn" onClick={() => { setOrderConfirmation(null); setPage('account') }}>متابعة طلباتي</button><button className="text-btn" onClick={() => setOrderConfirmation(null)}>العودة للمتجر</button></section></div>}
    {notice && <div className="toast" role="status"><Check size={16}/>{notice}<button onClick={() => setNotice('')} aria-label="إغلاق"><X size={14}/></button></div>}
  </div>
}

const ProductCard = memo(function ProductCard({ product, onOpen }: { product: Product; onOpen: (product: Product) => void }) {
  const image = product.images[0]
  const displayPrice = product.variants.length
    ? Math.min(...product.variants.map(variant => Number(variant.price_override ?? product.base_price)))
    : Number(product.base_price)
  const soldOut = product.variants.length > 0 && product.variants.every(variant => !variant.in_stock)
  return <article className="product-card"><button className="product-image" onClick={() => onOpen(product)} aria-label={`عرض ${product.name_ar}`}>
    {image ? <img src={productImageUrl(image.path) || ''} alt={image.alt_ar || product.name_ar} loading="lazy" decoding="async" width={600} height={800} sizes="(max-width: 640px) 48vw, (max-width: 900px) 30vw, 23vw" onError={e => { e.currentTarget.style.display = 'none' }}/> : <div className="image-placeholder"><span>DWLY<br/><small>NO IMAGE</small></span></div>}
    {product.is_featured && <span className="product-tag">اختيار DWLY</span>}{soldOut && <span className="product-tag sold-out">نفد المخزون</span>}<span className="quick-view">عرض المنتج <ArrowUpLeft size={15}/></span>
  </button><div className="product-info"><div><span className="product-category">{product.category?.name_ar || 'DWLY EGY'}</span><h3>{product.name_ar}</h3></div><div className="product-prices"><b>{money(displayPrice)}</b>{product.compare_at_price && <del>{money(product.compare_at_price)}</del>}</div></div><button className="card-open" onClick={() => onOpen(product)}>اختار المقاس واللون <ArrowLeft size={15}/></button></article>
})
function ProductDetail({ product, selected, onSelect, onBack, onAdd }: { product: Product; selected: ProductVariant | null; onSelect: (v: ProductVariant) => void; onBack: () => void; onAdd: () => void }) {
  const [activeImage, setActiveImage] = useState(0)
  const image = product.images[activeImage]
  const sizes = [...new Map(product.variants.filter(v => v.size).map(v => [v.size!.id, v.size!])).values()]
  const colors = [...new Map(product.variants.filter(v => v.color).map(v => [v.color!.id, v.color!])).values()]
  return <main className="detail-page"><button className="back-link" onClick={onBack}><ArrowLeft size={16}/> العودة للمنتجات</button><div className="detail-layout"><div className="detail-gallery"><div className="detail-main-image">{image ? <img src={productImageUrl(image.path) || ''} alt={image.alt_ar || product.name_ar} loading={activeImage === 0 ? 'eager' : 'lazy'} decoding="async" width={800} height={1000} onError={e => { e.currentTarget.style.display = 'none' }}/> : <div className="image-placeholder"><span>DWLY</span></div>}</div><div className="detail-thumbs">{product.images.map((img, index) => <button className={index === activeImage ? 'selected' : ''} key={img.id} onClick={() => setActiveImage(index)}><img src={productImageUrl(img.path) || ''} alt={img.alt_ar || ''} loading="lazy" decoding="async" width={65} height={78} onError={e => { e.currentTarget.style.display = 'none' }}/></button>)}</div></div><div className="detail-copy"><span className="eyebrow">{product.category?.name_ar || 'DWLY EGY'}</span><h1>{product.name_ar}</h1><div className="detail-price">{money(Number(selected?.price_override ?? product.base_price))}{product.compare_at_price && <del>{money(product.compare_at_price)}</del>}</div><p>{product.description_ar || 'تفاصيل المنتج ومواصفاته ستظهر هنا عند إضافتها من إدارة المتجر.'}</p>
    {sizes.length > 0 && <div className="variant-group"><label>المقاس</label><div className="size-options">{sizes.map(size => { const variant = product.variants.find(v => v.size?.id === size.id && (!selected?.color || v.color?.id === selected.color.id)); return <button key={size.id} disabled={!variant || variant.in_stock === false} className={selected?.size?.id === size.id ? 'chosen' : ''} onClick={() => variant && onSelect(variant)}>{size.label}</button> })}</div></div>}
    {colors.length > 0 && <div className="variant-group"><label>اللون {selected?.color && <span>· {selected.color.name_ar}</span>}</label><div className="color-options">{colors.map(color => { const variant = product.variants.find(v => v.color?.id === color.id && (!selected?.size || v.size?.id === selected.size.id)); return <button key={color.id} disabled={!variant || variant.in_stock === false} className={selected?.color?.id === color.id ? 'chosen' : ''} style={{ '--swatch': color.hex } as React.CSSProperties} onClick={() => variant && onSelect(variant)} aria-label={color.name_ar}><i/></button> })}</div></div>}
    {product.variants.length === 0 ? <p className="muted">لا توجد خيارات منشورة لهذا المنتج حاليًا.</p> : <button className="primary-btn full-btn" disabled={!selected || selected.in_stock === false} onClick={onAdd}>{selected?.in_stock === false ? 'غير متاح حاليًا' : 'أضف للسلة'} <ShoppingBag size={17}/></button>}
    <div className="detail-assurance"><span>01 — منتجات من الكتالوج الحقيقي</span><span>02 — الكمية تتحقق من الخادم عند الإضافة</span></div>
  </div></div></main>
}


type ShippingZone = { id: number; name_ar: string; fee: number | null; is_available: boolean }
type CartQuote = { subtotal: number; shipping_fee: number; discount_amount: number; total: number; lines: Array<{name:string;size:string|null;color:string|null;quantity:number;unit_price:number;line_total:number}> }
function orderStatusLabel(status: string) {
  const labels: Record<string,string> = { pending:'قيد المراجعة', confirmed:'تم التأكيد', processing:'قيد التجهيز', shipped:'تم الشحن', out_for_delivery:'في الطريق إليك', delivered:'تم التسليم', cancelled:'ملغي', refunded:'مسترد' }
  return labels[status] || status
}
function CheckoutPanel({ session, onClose, onSuccess }: { session: Session; onClose:()=>void; onSuccess:(order:{order_number:string;total:number})=>void }) {
  const [zones,setZones] = useState<ShippingZone[]>([])
  const [zoneId,setZoneId] = useState('')
  const [name,setName] = useState(String(session.user.user_metadata?.full_name || ''))
  const [phoneValue,setPhoneValue] = useState(String(session.user.user_metadata?.phone || ''))
  const [city,setCity] = useState('')
  const [address,setAddress] = useState('')
  const [notes,setNotes] = useState('')
  const [discount,setDiscount] = useState('')
  const [quote,setQuote] = useState<CartQuote|null>(null)
  const [busy,setBusy] = useState(false)
  const [error,setError] = useState('')
  const [terms,setTerms] = useState(false)
  const [saveAddress,setSaveAddress] = useState(true)
  const [savedAddresses,setSavedAddresses] = useState<Array<{id:string;recipient_name:string;phone:string;governorate_id:number;city:string;address_line:string;delivery_notes:string|null}>>([])
  const keyRef = useRef<string|null>(null)
  const storageKey = `dwly_checkout_idempotency_${session.user.id}`
  useEffect(() => {
    if (!supabase) return
    let active=true
    Promise.all([
      supabase.from('shipping_zones').select('id,name_ar,fee,is_available').eq('is_available',true).order('id'),
      supabase.from('addresses').select('id,recipient_name,phone,governorate_id,city,address_line,delivery_notes').eq('user_id',session.user.id).order('created_at',{ascending:false})
    ]).then(([z,a])=>{ if(!active)return; if(z.error) setError('تعذر تحميل مناطق الشحن.'); else { setZones(z.data||[]); const cairo=(z.data||[]).find(x=>x.name_ar==='القاهرة'); if(cairo) setZoneId(String(cairo.id)) }; if(!a.error) setSavedAddresses(a.data||[]) })
    return ()=>{active=false}
  },[session.user.id])
  const calculate = async () => {
    if(!supabase || !zoneId){setError('اختار المحافظة أولًا.');return}
    setBusy(true);setError('');
    const {data,error:rpcError}=await supabase.rpc('quote_cart',{p_governorate_id:Number(zoneId),p_discount_code:discount.trim()||null})
    if(rpcError){setQuote(null);setError(readableCheckoutError(rpcError.message));} else setQuote(data as CartQuote)
    setBusy(false)
  }
  const submit = async (event:React.FormEvent) => {
    event.preventDefault(); if(!supabase)return
    if(!terms){setError('لازم توافق على شروط الطلب.');return}
    if(!quote){await calculate();setError('راجع عرض السعر ثم اضغط تأكيد الطلب مرة أخرى.');return}
    if(!keyRef.current){keyRef.current=localStorage.getItem(storageKey)||crypto.randomUUID();localStorage.setItem(storageKey,keyRef.current)}
    setBusy(true);setError('')
    const {data,error:rpcError}=await supabase.rpc('place_order',{
      p_customer_name:name.trim(),p_phone:phoneValue.trim(),p_governorate_id:Number(zoneId),p_city:city.trim(),p_address_line:address.trim(),
      p_delivery_notes:notes.trim()||null,p_payment_method:'cod',p_discount_code:discount.trim()||null,p_terms_accepted:true,p_idempotency_key:keyRef.current
    })
    if(rpcError){setError(readableCheckoutError(rpcError.message)+' لو حصل انقطاع اتصال، أعد المحاولة بنفس الصفحة؛ مفتاح الطلب محفوظ لتجنب التكرار.');setBusy(false);return}
    localStorage.removeItem(storageKey)
    if(saveAddress){const {data:existingAddress}=await supabase.from('addresses').select('id').eq('user_id',session.user.id).eq('recipient_name',name.trim()).eq('phone',phoneValue.trim()).eq('governorate_id',Number(zoneId)).eq('city',city.trim()).eq('address_line',address.trim()).limit(1); if(!existingAddress?.length){const {error:addressError}=await supabase.from('addresses').insert({user_id:session.user.id,recipient_name:name.trim(),phone:phoneValue.trim(),governorate_id:Number(zoneId),city:city.trim(),address_line:address.trim(),delivery_notes:notes.trim()||null,is_default:savedAddresses.length===0}); if(addressError) setError('تم تسجيل الطلب، لكن تعذر حفظ العنوان في دفتر العناوين.');}}
    onSuccess({order_number:String(data.order_number),total:Number(data.total)})
    setBusy(false)
  }
  const chooseAddress=(id:string)=>{const a=savedAddresses.find(x=>x.id===id);if(!a)return;setName(a.recipient_name);setPhoneValue(a.phone);setZoneId(String(a.governorate_id));setCity(a.city);setAddress(a.address_line);setNotes(a.delivery_notes||'');setQuote(null)}
  return <div className="overlay" onMouseDown={e=>{if(e.target===e.currentTarget&&!busy)onClose()}}><section className="checkout-panel"><div className="drawer-head"><div><span className="eyebrow">SECURE CHECKOUT</span><h2>بيانات التوصيل</h2></div><button className="icon-btn" onClick={onClose} disabled={busy} aria-label="إغلاق"><X/></button></div>
    {savedAddresses.length>0&&<label>استخدم عنوان محفوظ<select defaultValue="" onChange={e=>chooseAddress(e.target.value)}><option value="">عنوان جديد</option>{savedAddresses.map(a=><option key={a.id} value={a.id}>{a.recipient_name} — {a.city} — {a.address_line}</option>)}</select></label>}
    <form className="checkout-form" onSubmit={submit}><label>الاسم بالكامل<input required value={name} onChange={e=>{setName(e.target.value);setQuote(null)}}/></label><label>رقم الموبايل<input required inputMode="tel" value={phoneValue} onChange={e=>{setPhoneValue(e.target.value);setQuote(null)}}/></label><label>المحافظة<select required value={zoneId} onChange={e=>{setZoneId(e.target.value);setQuote(null)}}><option value="">اختار المحافظة</option>{zones.map(z=><option key={z.id} value={z.id}>{z.name_ar} — {money(Number(z.fee))}</option>)}</select></label><label>المدينة / المنطقة<input required value={city} onChange={e=>{setCity(e.target.value);setQuote(null)}}/></label><label className="wide-field">العنوان بالتفصيل<input required value={address} onChange={e=>{setAddress(e.target.value);setQuote(null)}}/></label><label className="wide-field">علامة مميزة أو ملاحظات (اختياري)<textarea value={notes} onChange={e=>{setNotes(e.target.value);setQuote(null)}}/></label><label className="wide-field">كود الخصم (اختياري)<div className="discount-entry"><input value={discount} onChange={e=>{setDiscount(e.target.value.toUpperCase());setQuote(null)}} placeholder="DISCOUNT CODE"/><button type="button" className="outline-btn" onClick={()=>void calculate()} disabled={busy}>تطبيق وحساب</button></div></label>
    <label className="check-line wide-field"><input type="checkbox" checked={saveAddress} onChange={e=>setSaveAddress(e.target.checked)}/> احفظ العنوان في حسابي</label><label className="check-line wide-field"><input type="checkbox" checked={terms} onChange={e=>setTerms(e.target.checked)}/> أوافق على بيانات الطلب وشروط الشراء</label>
    {quote&&<div className="quote-summary wide-field"><div><span>المجموع الفرعي</span><b>{money(Number(quote.subtotal))}</b></div><div><span>الشحن</span><b>{money(Number(quote.shipping_fee))}</b></div><div><span>الخصم</span><b>− {money(Number(quote.discount_amount))}</b></div><div className="quote-total"><span>الإجمالي</span><strong>{money(Number(quote.total))}</strong></div></div>}
    {error&&<p className="form-error wide-field">{error}</p>}<button type="button" className="outline-btn full-btn wide-field" onClick={()=>void calculate()} disabled={busy}>{busy?'جاري المعالجة...':'احسب الإجمالي من قاعدة البيانات'}</button><button className="primary-btn full-btn wide-field" disabled={busy||!terms}>{busy?'جاري تأكيد الطلب...':'تأكيد الطلب — الدفع عند الاستلام'}</button></form>
    <p className="checkout-note">السعر والمخزون والشحن والخصم يعاد التحقق منها داخل PostgreSQL عند تسجيل الطلب. لا يتم تنفيذ دفع إلكتروني.</p></section></div>
}
function readableCheckoutError(message:string){
  const m=message.toUpperCase();
  if(m.includes('EMAIL_NOT_VERIFIED'))return 'أكد بريدك الإلكتروني قبل إتمام الطلب.';
  if(m.includes('CART_EMPTY'))return 'السلة فارغة.';
  if(m.includes('INSUFFICIENT_STOCK'))return 'الكمية المطلوبة لم تعد متاحة.';
  if(m.includes('SHIPPING_UNAVAILABLE'))return 'الشحن غير متاح للمحافظة المختارة.';
  if(m.includes('INVALID_DISCOUNT'))return 'كود الخصم غير صالح أو لا تنطبق شروطه.';
  if(m.includes('IDEMPOTENCY_KEY_REUSED'))return 'تم استخدام مفتاح الطلب ببيانات مختلفة. تواصل مع الدعم قبل إنشاء طلب جديد.';
  if(m.includes('INVALID_PHONE'))return 'رقم الموبايل غير صحيح.';
  return 'تعذر تأكيد الطلب من قاعدة البيانات.';
}

function AccountPage(props: {
  session: Session | null; authReady: boolean; authMode: 'signin' | 'signup'; setAuthMode: (v: 'signin' | 'signup') => void;
  email: string; setEmail: (v: string) => void; password: string; setPassword: (v: string) => void; fullName: string; setFullName: (v: string) => void;
  phone: string; setPhone: (v: string) => void; busy: boolean; error: string; onSubmit: (e: React.FormEvent) => void; onSignOut: () => void;
}) {
  const [orders, setOrders] = useState<Array<{id:string;order_number:string;status:string;total:number;created_at:string}>>([])
  const [ordersBusy, setOrdersBusy] = useState(false)
  const [ordersError, setOrdersError] = useState('')
  useEffect(() => {
    if (!props.session || !supabase) return
    let active = true
    setOrdersBusy(true); setOrdersError('')
    supabase.from('orders').select('id,order_number,status,total,created_at').eq('user_id', props.session.user.id).order('created_at', {ascending:false}).limit(25)
      .then(({data,error}) => { if (!active) return; if (error) setOrdersError('تعذر تحميل طلباتك. حاول تحديث الصفحة.'); else setOrders(data || []); setOrdersBusy(false) })
    return () => { active = false }
  }, [props.session?.user.id])
  if (!props.authReady) return <div className="state-panel"><LoaderCircle className="spin"/> جاري التحقق من الحساب...</div>
  if (props.session) return <main className="account-page"><span className="eyebrow">MY DWLY</span><h1>أهلاً بيك</h1><p>{props.session.user.email}</p><div className="account-panel"><UserRound/><div><b>حسابك متصل</b><small>تقدر تتابع طلباتك من هنا.</small></div></div><section className="orders-panel"><div className="section-heading"><div><span className="eyebrow">ORDER HISTORY</span><h2>طلباتي</h2></div></div>{ordersBusy ? <p>جاري تحميل الطلبات...</p> : ordersError ? <p className="form-error">{ordersError}</p> : orders.length === 0 ? <p>لسه مفيش طلبات على حسابك.</p> : orders.map(order => <article className="order-row" key={order.id}><div><b>{order.order_number}</b><small>{new Date(order.created_at).toLocaleDateString('ar-EG')}</small></div><span>{orderStatusLabel(order.status)}</span><strong>{money(Number(order.total))}</strong></article>)}</section><button className="outline-btn" onClick={props.onSignOut}>تسجيل الخروج</button></main>
  return <main className="account-page"><span className="eyebrow">WELCOME TO DWLY</span><h1>{props.authMode === 'signin' ? 'سجّل دخولك.' : 'حساب جديد.'}</h1><p>سجّل دخولك عشان تتابع تجربة الشراء.</p><form className="auth-form" onSubmit={props.onSubmit}>
    {props.authMode === 'signup' && <><label>الاسم بالكامل<input required value={props.fullName} onChange={e => props.setFullName(e.target.value)} autoComplete="name"/></label><label>رقم الموبايل<input required value={props.phone} onChange={e => props.setPhone(e.target.value)} autoComplete="tel" inputMode="tel"/></label></>}
    <label>البريد الإلكتروني<input type="email" required value={props.email} onChange={e => props.setEmail(e.target.value)} autoComplete="email"/></label><label>كلمة المرور<input type="password" required minLength={8} value={props.password} onChange={e => props.setPassword(e.target.value)} autoComplete={props.authMode === 'signin' ? 'current-password' : 'new-password'}/></label>
    {props.error && <p className="form-error">{props.error}</p>}<button className="primary-btn full-btn" disabled={props.busy || !isSupabaseConfigured}>{props.busy ? <LoaderCircle className="spin"/> : <LogIn size={17}/>} {props.authMode === 'signin' ? 'تسجيل الدخول' : 'إنشاء الحساب'}</button>
    <button type="button" className="text-btn" onClick={() => props.setAuthMode(props.authMode === 'signin' ? 'signup' : 'signin')}>{props.authMode === 'signin' ? 'لسه معندكش حساب؟ أنشئ حساب جديد' : 'عندك حساب بالفعل؟ سجّل الدخول'}</button>
  </form></main>
}
