import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertCircle, ArrowRight, BarChart3, Check, ImagePlus, LoaderCircle, Package, Plus, RefreshCw, ShoppingCart, Tags, Users, Warehouse, X } from 'lucide-react'
import type { Session } from '@supabase/supabase-js'
import { supabase, productImageUrl } from './lib/supabase'

type Tab = 'overview' | 'products' | 'categories' | 'stock' | 'orders' | 'customers'
type Category = { id: string; name_ar: string; slug: string; parent_id: string | null; is_active: boolean }
type ProductRow = { id: string; name_ar: string; slug: string; gender: string; base_price: number; compare_at_price: number | null; description_ar: string | null; status: string; is_featured: boolean; category_id: string | null; created_at: string; variants?: Array<{id:string;sku:string;size_id:number|null;color_id:number|null;is_active:boolean}>; images?: Array<{id:string;path:string;is_primary:boolean}> }
type Size = { id: number; label: string }
type Color = { id: number; name_ar: string; hex: string }
type OrderRow = { id:string; order_number:string; status:string; payment_status:string; payment_method:string; customer_name:string; phone:string; governorate_name:string; city:string; address_line:string; total:number; created_at:string }
type StockRow = { variant_id:string; quantity:number; low_stock_threshold:number; product_variants:{sku:string;size_id:number|null;color_id:number|null;products:{name_ar:string}} }
type ProfileRow = { id:string; email:string|null; full_name:string|null; phone:string|null; is_active:boolean; created_at:string }

const statusLabels: Record<string,string> = { draft:'مسودة', active:'منشور', archived:'مؤرشف', pending:'جديد', confirmed:'تم التأكيد', processing:'قيد التجهيز', shipped:'تم الشحن', out_for_delivery:'خرج للتوصيل', delivered:'تم التسليم', cancelled:'ملغي', refunded:'مسترد', unpaid:'غير مدفوع', paid:'مدفوع', failed:'فشل' }
const transitions: Record<string,string[]> = { pending:['confirmed','cancelled'], confirmed:['processing','cancelled'], processing:['shipped','cancelled'], shipped:['out_for_delivery'], out_for_delivery:['delivered','cancelled'] }
const money = (n:number) => new Intl.NumberFormat('ar-EG',{maximumFractionDigits:2}).format(Number(n||0))+' ج.م'
const message = (e:any) => e?.message || 'حصل خطأ غير متوقع. حاول مرة تانية.'
const slugify = (s:string) => s.trim().toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'')

export default function AdminDashboard({ session, onExit }: { session:Session|null; onExit:()=>void }) {
  const [tab,setTab] = useState<Tab>('overview')
  const [authorized,setAuthorized] = useState(false)
  const [checking,setChecking] = useState(true)
  const [busy,setBusy] = useState(false)
  const [error,setError] = useState('')
  const [notice,setNotice] = useState('')
  const [stats,setStats] = useState<any>(null)
  const [products,setProducts] = useState<ProductRow[]>([])
  const [categories,setCategories] = useState<Category[]>([])
  const [sizes,setSizes] = useState<Size[]>([])
  const [colors,setColors] = useState<Color[]>([])
  const [orders,setOrders] = useState<OrderRow[]>([])
  const [stock,setStock] = useState<StockRow[]>([])
  const [customers,setCustomers] = useState<ProfileRow[]>([])
  const [productSearch,setProductSearch] = useState('')
  const [showProductForm,setShowProductForm] = useState(false)
  const [editing,setEditing] = useState<ProductRow|null>(null)
  const [productName,setProductName] = useState('')
  const [productSlug,setProductSlug] = useState('')
  const [gender,setGender] = useState('men')
  const [price,setPrice] = useState('')
  const [comparePrice,setComparePrice] = useState('')
  const [categoryId,setCategoryId] = useState('')
  const [description,setDescription] = useState('')
  const [productStatus,setProductStatus] = useState('draft')
  const [featured,setFeatured] = useState(false)
  const [variantProduct,setVariantProduct] = useState<ProductRow|null>(null)
  const [sku,setSku] = useState('')
  const [sizeId,setSizeId] = useState('')
  const [colorId,setColorId] = useState('')
  const [initialQty,setInitialQty] = useState('0')
  const [variantPrice,setVariantPrice] = useState('')
  const [imageProduct,setImageProduct] = useState<ProductRow|null>(null)
  const [imageFiles,setImageFiles] = useState<FileList|null>(null)
  const [categoryName,setCategoryName] = useState('')
  const [categorySlug,setCategorySlug] = useState('')
  const [categoryParent,setCategoryParent] = useState('')
  const [stockDelta,setStockDelta] = useState<Record<string,string>>({})
  const [orderNotes,setOrderNotes] = useState<Record<string,string>>({})

  const loadAll = useCallback(async () => {
    if (!supabase || !session) { setChecking(false); setAuthorized(false); return }
    setBusy(true); setError('')
    const [statRes,catRes,sizeRes,colorRes,prodRes,orderRes,stockRes,customerRes] = await Promise.all([
      supabase.rpc('admin_dashboard_stats'),
      supabase.from('categories').select('id,name_ar,slug,parent_id,is_active').order('sort_order'),
      supabase.from('sizes').select('id,label').order('sort_order'),
      supabase.from('colors').select('id,name_ar,hex').order('name_ar'),
      supabase.from('products').select('id,name_ar,slug,gender,base_price,compare_at_price,description_ar,status,is_featured,category_id,created_at,variants:product_variants(id,sku,size_id,color_id,is_active),images:product_images(id,path,is_primary)').order('created_at',{ascending:false}).limit(200),
      supabase.from('orders').select('id,order_number,status,payment_status,payment_method,customer_name,phone,governorate_name,city,address_line,total,created_at').order('created_at',{ascending:false}).limit(100),
      supabase.from('inventory').select('variant_id,quantity,low_stock_threshold,product_variants!inner(sku,size_id,color_id,products!inner(name_ar))').order('updated_at',{ascending:false}).limit(300),
      supabase.from('profiles').select('id,email,full_name,phone,is_active,created_at').order('created_at',{ascending:false}).limit(200),
    ])
    if (statRes.error) {
      setAuthorized(false); setChecking(false)
      setError(statRes.error.message.toLowerCase().includes('forbidden') || statRes.error.code === '42501' ? 'الحساب ده مش عنده صلاحية إدارة المتجر. لازم يتضاف له دور Admin أو Staff من Supabase.' : `تعذر التحقق من صلاحية الإدارة: ${message(statRes.error)}`)
      setBusy(false); return
    }
    setAuthorized(true); setStats(statRes.data)
    if (catRes.error || sizeRes.error || colorRes.error || prodRes.error || orderRes.error || stockRes.error || customerRes.error) {
      const first = [catRes,sizeRes,colorRes,prodRes,orderRes,stockRes,customerRes].find(x=>x.error)?.error
      setError(`تم التحقق من صلاحية الإدارة، لكن بعض البيانات لم تُحمّل: ${message(first)}`)
    }
    setCategories(catRes.data||[]); setSizes(sizeRes.data||[]); setColors(colorRes.data||[]); setProducts((prodRes.data||[]) as any); setOrders((orderRes.data||[]) as any); setStock((stockRes.data||[]) as any); setCustomers(customerRes.data||[])
    setChecking(false); setBusy(false)
  },[session])

  useEffect(()=>{ void loadAll() },[loadAll])
  const visibleProducts = useMemo(()=>products.filter(p=>`${p.name_ar} ${p.slug} ${p.status}`.toLowerCase().includes(productSearch.toLowerCase())),[products,productSearch])
  const lowStock = stock.filter(x=>x.quantity<=x.low_stock_threshold)

  const openNewProduct = () => { setEditing(null); setProductName(''); setProductSlug(''); setGender('men'); setPrice(''); setComparePrice(''); setCategoryId(''); setDescription(''); setProductStatus('draft'); setFeatured(false); setShowProductForm(true) }
  const openEditProduct = (p:ProductRow) => { setEditing(p); setProductName(p.name_ar); setProductSlug(p.slug); setGender(p.gender); setPrice(String(p.base_price)); setComparePrice(p.compare_at_price===null?'':String(p.compare_at_price)); setCategoryId(p.category_id||''); setDescription(p.description_ar||''); setProductStatus(p.status); setFeatured(p.is_featured); setShowProductForm(true) }
  const saveProduct = async (e:React.FormEvent) => {
    e.preventDefault(); if(!supabase) return
    setBusy(true); setError(''); setNotice('')
    const payload = {name_ar:productName.trim(),slug:productSlug.trim()||slugify(productName),gender,base_price:Number(price),compare_at_price:comparePrice?Number(comparePrice):null,category_id:categoryId||null,description_ar:description.trim()||null,status:productStatus,is_featured:featured,is_demo:false}
    if(!payload.name_ar || !payload.slug || !Number.isFinite(payload.base_price) || payload.base_price<0 || (payload.compare_at_price!==null && payload.compare_at_price<=payload.base_price) || (productStatus==='active' && (!editing || !(editing.variants?.length) || !(editing.images?.length)))) { setError('راجع الاسم والرابط والسعر. سعر المقارنة لازم يكون أكبر من سعر البيع، ولا يمكن نشر منتج قبل إضافة متغير واحد وصورة على الأقل.'); setBusy(false); return }
    const result = editing ? await supabase.from('products').update(payload).eq('id',editing.id).select('id').single() : await supabase.from('products').insert(payload).select('id').single()
    if(result.error) setError(message(result.error)); else { setNotice(editing?'تم تحديث المنتج.':'تم إنشاء المنتج كمسودة. أضف المتغيرات والصور ثم انشره.'); setShowProductForm(false); await loadAll() }
    setBusy(false)
  }
  const addVariant = async (e:React.FormEvent) => {
    e.preventDefault(); if(!supabase||!variantProduct) return
    setBusy(true); setError('');
    if(!sku.trim() || !Number.isInteger(Number(initialQty)) || Number(initialQty)<0 || (variantPrice!=='' && (!Number.isFinite(Number(variantPrice)) || Number(variantPrice)<0))) {setError('راجع SKU والكمية والسعر. الكمية لازم تكون رقمًا صحيحًا غير سالب.');setBusy(false);return}
    const result=await supabase.from('product_variants').insert({product_id:variantProduct.id,sku:sku.trim(),size_id:sizeId?Number(sizeId):null,color_id:colorId?Number(colorId):null,price_override:variantPrice?Number(variantPrice):null}).select('id').single()
    if(result.error){setError(message(result.error));setBusy(false);return}
    const q=Math.max(0,Number(initialQty)||0)
    if(q>0){const stockRes=await supabase.rpc('admin_adjust_inventory',{p_variant_id:result.data.id,p_delta:q,p_reason:'initial',p_note:'رصيد افتتاحي من لوحة الإدارة'});if(stockRes.error){setError(`تم إنشاء المتغير لكن تعذر إضافة رصيده: ${message(stockRes.error)}`);setBusy(false);await loadAll();return}}
    setNotice('تمت إضافة المقاس/اللون ورصيد المخزون.');setVariantProduct(null);setSku('');setSizeId('');setColorId('');setInitialQty('0');setVariantPrice('');await loadAll();setBusy(false)
  }
  const uploadImages = async (e:React.FormEvent) => {
    e.preventDefault(); if(!supabase||!imageProduct||!imageFiles?.length) return
    setBusy(true);setError('');let uploaded=0
    for(const file of Array.from(imageFiles)){
      if(!['image/jpeg','image/png','image/webp','image/avif'].includes(file.type)||file.size>5*1024*1024){setError('الصور لازم تكون JPG أو PNG أو WEBP أو AVIF وحجم الصورة لا يزيد عن 5MB.');continue}
      const ext=file.name.split('.').pop()?.toLowerCase()||'jpg';const path=`${imageProduct.id}/${crypto.randomUUID()}.${ext}`
      const up=await supabase.storage.from('product-images').upload(path,file,{contentType:file.type,upsert:false})
      if(up.error){setError(message(up.error));continue}
      const primary=!(imageProduct.images||[]).some(x=>x.is_primary)&&uploaded===0
      const row=await supabase.from('product_images').insert({product_id:imageProduct.id,path,alt_ar:imageProduct.name_ar,is_primary:primary,sort_order:(imageProduct.images?.length||0)+uploaded}).select('id').single()
      if(row.error){setError(`تم رفع الملف لكن تعذر ربطه بالمنتج: ${message(row.error)}`);continue}uploaded++
    }
    if(uploaded)setNotice(`تم رفع وربط ${uploaded} صورة.`)
    setImageProduct(null);setImageFiles(null);await loadAll();setBusy(false)
  }
  const addCategory = async(e:React.FormEvent)=>{e.preventDefault();if(!supabase)return;setBusy(true);setError('');const slug=categorySlug.trim()||slugify(categoryName);const r=await supabase.from('categories').insert({name_ar:categoryName.trim(),slug,parent_id:categoryParent||null,is_demo:false}).select('id').single();if(r.error)setError(message(r.error));else{setNotice('تمت إضافة القسم.');setCategoryName('');setCategorySlug('');setCategoryParent('');await loadAll()}setBusy(false)}
  const toggleCategory = async(c:Category)=>{if(!supabase)return;setBusy(true);const r=await supabase.from('categories').update({is_active:!c.is_active}).eq('id',c.id);if(r.error)setError(message(r.error));else await loadAll();setBusy(false)}
  const adjustStock = async(id:string)=>{if(!supabase)return;const delta=Number(stockDelta[id]);if(!Number.isInteger(delta)||delta===0){setError('اكتب فرق كمية صحيح، موجب للإضافة وسالب للخصم.');return}setBusy(true);setError('');const r=await supabase.rpc('admin_adjust_inventory',{p_variant_id:id,p_delta:delta,p_reason:'adjustment',p_note:'تعديل من لوحة إدارة DWLY EGY'});if(r.error)setError(message(r.error));else{setNotice(`تم تحديث المخزون إلى ${r.data} قطعة.`);setStockDelta(v=>({...v,[id]:''}));await loadAll()}setBusy(false)}
  const changeOrder = async(o:OrderRow,next:string)=>{if(!supabase)return;setBusy(true);setError('');const r=await supabase.rpc('admin_set_order_status',{p_order_id:o.id,p_status:next,p_note:orderNotes[o.id]||null});if(r.error)setError(message(r.error));else{setNotice(`تم تحديث حالة الطلب ${o.order_number}.`);await loadAll()}setBusy(false)}

  if(checking)return <main className="admin-page"><div className="state-panel"><LoaderCircle className="spin"/> جاري التحقق من صلاحيات الإدارة...</div></main>
  if(!session)return <main className="admin-page"><h1>لوحة الإدارة</h1><p>سجّل الدخول بحساب الإدارة أولًا.</p><button className="primary-btn" onClick={onExit}>العودة لتسجيل الدخول</button></main>
  if(!authorized)return <main className="admin-page"><div className="admin-denied"><AlertCircle size={36}/><h1>الدخول للوحة الإدارة غير متاح</h1><p>{error||'الحساب الحالي ليس لديه صلاحية إدارة المتجر.'}</p><p>لا يمكن منح الصلاحية من الموقع نفسه. يتم تعيين أول Admin بأمان من Supabase بعد التأكد من البريد الإلكتروني للحساب.</p><button className="outline-btn" onClick={onExit}>العودة للمتجر</button></div></main>

  const nav: Array<{id:Tab;label:string;icon:any}>=[{id:'overview',label:'نظرة عامة',icon:BarChart3},{id:'products',label:'المنتجات',icon:Package},{id:'categories',label:'الأقسام',icon:Tags},{id:'stock',label:'المخزون',icon:Warehouse},{id:'orders',label:'الطلبات',icon:ShoppingCart},{id:'customers',label:'العملاء',icon:Users}]
  return <main className="admin-page" dir="rtl">
    <div className="admin-heading"><div><span className="eyebrow">DWLY EGY · CONTROL CENTER</span><h1>لوحة الإدارة</h1><p>{session.user.email}</p></div><div className="admin-heading-actions"><button className="outline-btn" onClick={()=>void loadAll()} disabled={busy}><RefreshCw size={15}/> تحديث</button><button className="outline-btn" onClick={onExit}><ArrowRight size={15}/> المتجر</button></div></div>
    {error&&<div className="admin-alert error"><AlertCircle size={17}/>{error}<button onClick={()=>setError('')}><X size={15}/></button></div>}{notice&&<div className="admin-alert success"><Check size={17}/>{notice}<button onClick={()=>setNotice('')}><X size={15}/></button></div>}
    <div className="admin-layout"><aside className="admin-sidebar">{nav.map(n=><button key={n.id} className={tab===n.id?'selected':''} onClick={()=>setTab(n.id)}><n.icon size={17}/>{n.label}</button>)}</aside><section className="admin-content">
      {tab==='overview'&&<><div className="admin-section-title"><div><h2>ملخص المتجر</h2><p>آخر 30 يوم حسب بيانات الطلبات.</p></div></div><div className="admin-stat-grid"><article><span>إجمالي المبيعات</span><strong>{money(Number(stats?.total_sales||0))}</strong></article><article><span>عدد الطلبات</span><strong>{stats?.total_orders??0}</strong></article><article><span>طلبات جديدة</span><strong>{stats?.pending_orders??0}</strong></article><article><span>مخزون منخفض</span><strong>{stats?.low_stock_variants??lowStock.length}</strong></article></div><div className="admin-two-col"><section className="admin-card"><h3>آخر الطلبات</h3>{orders.slice(0,5).map(o=><div className="admin-list-row" key={o.id}><div><b>{o.order_number}</b><small>{o.customer_name}</small></div><span>{statusLabels[o.status]||o.status}</span><strong>{money(Number(o.total))}</strong></div>)}{!orders.length&&<p className="muted">لا توجد طلبات حتى الآن.</p>}</section><section className="admin-card"><h3>تنبيهات المخزون</h3>{lowStock.slice(0,8).map(s=><div className="admin-list-row" key={s.variant_id}><div><b>{s.product_variants?.products?.name_ar}</b><small>{s.product_variants?.sku}</small></div><span className="stock-warning">{s.quantity} قطعة</span></div>)}{!lowStock.length&&<p className="muted">لا توجد أصناف منخفضة المخزون.</p>}</section></div></>}
      {tab==='products'&&<><div className="admin-section-title"><div><h2>إدارة المنتجات</h2><p>{products.length} منتج في قاعدة البيانات.</p></div><button className="primary-btn" onClick={openNewProduct}><Plus size={16}/> منتج جديد</button></div><input className="admin-search" placeholder="ابحث باسم المنتج أو الرابط..." value={productSearch} onChange={e=>setProductSearch(e.target.value)}/><div className="admin-table-wrap"><table className="admin-table"><thead><tr><th>المنتج</th><th>القسم / النوع</th><th>السعر</th><th>المتغيرات</th><th>الحالة</th><th>إجراءات</th></tr></thead><tbody>{visibleProducts.map(p=><tr key={p.id}><td><b>{p.name_ar}</b><small>{p.slug}</small></td><td>{categories.find(c=>c.id===p.category_id)?.name_ar||'—'}<small>{p.gender==='men'?'رجالي':p.gender==='women'?'حريمي':'يونيسكس'}</small></td><td>{money(Number(p.base_price))}</td><td>{p.variants?.length||0}</td><td><span className={`admin-pill ${p.status}`}>{statusLabels[p.status]||p.status}</span></td><td><div className="admin-actions"><button onClick={()=>openEditProduct(p)}>تعديل</button><button onClick={()=>setVariantProduct(p)}>متغير + مخزون</button><button onClick={()=>setImageProduct(p)}><ImagePlus size={14}/> صور</button>{p.status==='draft'&&<button onClick={async()=>{if(!supabase)return;if(!(p.variants?.length)||!(p.images?.length)){setError('أضف متغيرًا واحدًا وصورة على الأقل قبل نشر المنتج.');return}setBusy(true);const r=await supabase.from('products').update({status:'active'}).eq('id',p.id);if(r.error)setError(message(r.error));else{setNotice('تم نشر المنتج.');await loadAll()}setBusy(false)}}>نشر</button>}{p.status==='active'&&<button onClick={async()=>{if(!supabase)return;setBusy(true);const r=await supabase.from('products').update({status:'archived'}).eq('id',p.id);if(r.error)setError(message(r.error));else{setNotice('تم أرشفة المنتج.');await loadAll()}setBusy(false)}}>أرشفة</button>}</div></td></tr>)}</tbody></table>{!visibleProducts.length&&<p className="admin-empty">لا توجد منتجات مطابقة.</p>}</div></>}
      {tab==='categories'&&<><div className="admin-section-title"><div><h2>الأقسام</h2><p>إضافة أقسام رئيسية وفرعية والتحكم في ظهورها.</p></div></div><form className="admin-inline-form" onSubmit={addCategory}><label>اسم القسم<input required value={categoryName} onChange={e=>{setCategoryName(e.target.value);if(!categorySlug)setCategorySlug(slugify(e.target.value))}} placeholder="مثال: تيشيرتات"/></label><label>الرابط بالإنجليزية<input required pattern="[a-z0-9]+(-[a-z0-9]+)*" value={categorySlug} onChange={e=>setCategorySlug(e.target.value)} placeholder="t-shirts"/></label><label>القسم الرئيسي<select value={categoryParent} onChange={e=>setCategoryParent(e.target.value)}><option value="">قسم رئيسي</option>{categories.filter(c=>!c.parent_id).map(c=><option key={c.id} value={c.id}>{c.name_ar}</option>)}</select></label><button className="primary-btn" disabled={busy}><Plus size={15}/> إضافة</button></form><div className="admin-card">{categories.map(c=><div className="admin-list-row" key={c.id}><div><b>{c.name_ar}</b><small>{c.slug} · {categories.find(p=>p.id===c.parent_id)?.name_ar||'رئيسي'}</small></div><span className={`admin-pill ${c.is_active?'active':'archived'}`}>{c.is_active?'نشط':'متوقف'}</span><button className="outline-btn small" onClick={()=>void toggleCategory(c)}>{c.is_active?'إيقاف':'تفعيل'}</button></div>)}</div></>}
      {tab==='stock'&&<><div className="admin-section-title"><div><h2>المخزون</h2><p>التعديل يتم من خلال إجراء آمن يسجل حركة المخزون.</p></div></div><div className="admin-table-wrap"><table className="admin-table"><thead><tr><th>المنتج</th><th>SKU</th><th>المتاح</th><th>حد التنبيه</th><th>فرق الكمية</th><th></th></tr></thead><tbody>{stock.map(s=><tr key={s.variant_id}><td>{s.product_variants?.products?.name_ar}</td><td>{s.product_variants?.sku}</td><td><b className={s.quantity<=s.low_stock_threshold?'stock-warning':''}>{s.quantity}</b></td><td>{s.low_stock_threshold}</td><td><input className="stock-delta" type="number" value={stockDelta[s.variant_id]??''} onChange={e=>setStockDelta(v=>({...v,[s.variant_id]:e.target.value}))} placeholder="+5 أو -2"/></td><td><button className="outline-btn small" onClick={()=>void adjustStock(s.variant_id)} disabled={busy}>حفظ</button></td></tr>)}</tbody></table>{!stock.length&&<p className="admin-empty">لا توجد متغيرات منتجات حتى الآن.</p>}</div><p className="admin-help">اكتب 5 لإضافة خمس قطع، أو -2 لخصم قطعتين. لا يمكن أن يصبح المخزون بالسالب.</p></>}
      {tab==='orders'&&<><div className="admin-section-title"><div><h2>الطلبات</h2><p>متابعة الطلبات وتحديث حالتها حسب دورة الشحن.</p></div></div><div className="admin-order-list">{orders.map(o=><article className="admin-order" key={o.id}><div className="admin-order-top"><div><b>{o.order_number}</b><small>{new Date(o.created_at).toLocaleString('ar-EG')}</small></div><strong>{money(Number(o.total))}</strong></div><div className="admin-order-details"><b>{o.customer_name}</b><span>{o.phone}</span><span>{o.governorate_name} · {o.city}</span><span>{o.address_line}</span><span>الدفع: {o.payment_method==='cod'?'عند الاستلام':o.payment_method} · {statusLabels[o.payment_status]||o.payment_status}</span></div><div className="admin-order-actions"><span className="admin-pill">{statusLabels[o.status]||o.status}</span>{(transitions[o.status]||[]).length>0&&<><input placeholder="ملاحظة اختيارية" value={orderNotes[o.id]||''} onChange={e=>setOrderNotes(v=>({...v,[o.id]:e.target.value}))}/><select defaultValue="" onChange={e=>{if(e.target.value)void changeOrder(o,e.target.value)}}><option value="">تحديث الحالة...</option>{transitions[o.status].map(s=><option key={s} value={s}>{statusLabels[s]}</option>)}</select></>}</div></article>)}{!orders.length&&<p className="admin-empty">لا توجد طلبات حتى الآن.</p>}</div></>}
      {tab==='customers'&&<><div className="admin-section-title"><div><h2>العملاء</h2><p>حسابات العملاء المسجلة في المتجر.</p></div></div><div className="admin-table-wrap"><table className="admin-table"><thead><tr><th>الاسم</th><th>البريد</th><th>الهاتف</th><th>الحالة</th><th>تاريخ التسجيل</th></tr></thead><tbody>{customers.map(c=><tr key={c.id}><td>{c.full_name||'—'}</td><td dir="ltr">{c.email||'—'}</td><td dir="ltr">{c.phone||'—'}</td><td>{c.is_active?'نشط':'موقوف'}</td><td>{new Date(c.created_at).toLocaleDateString('ar-EG')}</td></tr>)}</tbody></table>{!customers.length&&<p className="admin-empty">لا توجد حسابات عملاء.</p>}</div></>}
    </section></div>

    {showProductForm&&<div className="admin-modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setShowProductForm(false)}}><form className="admin-modal" onSubmit={saveProduct}><div className="admin-modal-head"><h2>{editing?'تعديل المنتج':'إضافة منتج جديد'}</h2><button type="button" onClick={()=>setShowProductForm(false)}><X/></button></div><label>اسم المنتج بالعربي<input required value={productName} onChange={e=>{setProductName(e.target.value);if(!editing)setProductSlug(slugify(e.target.value))}}/></label><label>رابط المنتج (Slug)<input required pattern="[a-z0-9]+(-[a-z0-9]+)*" value={productSlug} onChange={e=>setProductSlug(e.target.value)}/></label><div className="admin-form-grid"><label>القسم<select value={categoryId} onChange={e=>setCategoryId(e.target.value)}><option value="">بدون قسم</option>{categories.filter(c=>c.is_active).map(c=><option key={c.id} value={c.id}>{c.name_ar}</option>)}</select></label><label>الفئة<select value={gender} onChange={e=>setGender(e.target.value)}><option value="men">رجالي</option><option value="women">حريمي</option><option value="unisex">مشترك</option></select></label><label>سعر البيع (ج.م)<input required min="0" type="number" step="0.01" value={price} onChange={e=>setPrice(e.target.value)}/></label><label>سعر قبل الخصم (اختياري)<input min="0" type="number" step="0.01" value={comparePrice} onChange={e=>setComparePrice(e.target.value)}/></label><label>حالة المنتج<select value={productStatus} onChange={e=>setProductStatus(e.target.value)}><option value="draft">مسودة</option><option value="active">منشور</option><option value="archived">مؤرشف</option></select></label></div><label>وصف المنتج<textarea rows={3} value={description} onChange={e=>setDescription(e.target.value)}/></label><label className="admin-check"><input type="checkbox" checked={featured} onChange={e=>setFeatured(e.target.checked)}/> منتج مميز</label><p className="admin-help">المنتج الجديد يُحفظ كمسودة افتراضيًا. أضف متغيرًا وصورة قبل النشر.</p><button className="primary-btn full-btn" disabled={busy}>{busy?<LoaderCircle className="spin"/>:<Check size={16}/>} حفظ المنتج</button></form></div>}
    {variantProduct&&<div className="admin-modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setVariantProduct(null)}}><form className="admin-modal" onSubmit={addVariant}><div className="admin-modal-head"><h2>إضافة متغير · {variantProduct.name_ar}</h2><button type="button" onClick={()=>setVariantProduct(null)}><X/></button></div><label>SKU (كود فريد)<input required value={sku} onChange={e=>setSku(e.target.value)} placeholder="DW-M-TSH-BLK-M" dir="ltr"/></label><div className="admin-form-grid"><label>المقاس<select value={sizeId} onChange={e=>setSizeId(e.target.value)}><option value="">مقاس موحد</option>{sizes.map(s=><option key={s.id} value={s.id}>{s.label}</option>)}</select></label><label>اللون<select value={colorId} onChange={e=>setColorId(e.target.value)}><option value="">بدون لون</option>{colors.map(c=><option key={c.id} value={c.id}>{c.name_ar}</option>)}</select></label><label>سعر مختلف (اختياري)<input type="number" min="0" step="0.01" value={variantPrice} onChange={e=>setVariantPrice(e.target.value)}/></label><label>الكمية الافتتاحية<input required type="number" min="0" step="1" value={initialQty} onChange={e=>setInitialQty(e.target.value)}/></label></div><p className="admin-help">كل تركيبة مقاس/لون لازم يكون لها SKU مختلف. المخزون بيتسجل تلقائيًا في النظام.</p><button className="primary-btn full-btn" disabled={busy}>إضافة المتغير</button></form></div>}
    {imageProduct&&<div className="admin-modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setImageProduct(null)}}><form className="admin-modal" onSubmit={uploadImages}><div className="admin-modal-head"><h2>صور · {imageProduct.name_ar}</h2><button type="button" onClick={()=>setImageProduct(null)}><X/></button></div><label>اختار صورة أو أكتر<input required type="file" accept="image/jpeg,image/png,image/webp,image/avif" multiple onChange={e=>setImageFiles(e.target.files)}/></label><p className="admin-help">JPG / PNG / WEBP / AVIF، بحد أقصى 5MB للصورة. أول صورة للمنتج بتكون الصورة الرئيسية تلقائيًا.</p>{(imageProduct.images||[]).length>0&&<div className="admin-image-preview">{(imageProduct.images||[]).map(im=><img key={im.id} src={productImageUrl(im.path)||''} alt=""/>)}</div>}<button className="primary-btn full-btn" disabled={busy||!imageFiles?.length}>{busy?'جاري الرفع...':'رفع الصور'}</button></form></div>}
  </main>
}
