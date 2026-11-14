import { useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'

type Result = { status: 'idle' | 'running' | 'success' | 'error'; count: number | null; message: string }

const urlAvailable = Boolean(import.meta.env.VITE_SUPABASE_URL)
const anonKeyAvailable = Boolean(import.meta.env.VITE_SUPABASE_ANON_KEY)

export default function SupabaseDiagnostics() {
  const [result, setResult] = useState<Result>({ status: 'idle', count: null, message: 'لم يبدأ الاختبار بعد.' })
  const started = useRef(false)

  const runTest = async () => {
    if (!supabase) {
      setResult({ status: 'error', count: null, message: 'عميل Supabase غير مهيأ؛ أحد متغيرَي البيئة أو كلاهما غير متاح.' })
      return
    }

    setResult({ status: 'running', count: null, message: 'جارٍ تنفيذ SELECT بصلاحيات الزائر...' })
    try {
      const { data: sessionData, error: sessionError } = await supabase.auth.getSession()
      if (sessionError) {
        setResult({ status: 'error', count: null, message: 'تعذر التحقق من حالة جلسة المتصفح قبل الاختبار.' })
        return
      }
      if (sessionData.session) {
        setResult({ status: 'error', count: null, message: 'توجد جلسة دخول محفوظة في هذا المتصفح؛ لم ننسب نتيجة الاستعلام إلى صلاحيات الزائر المجهول.' })
        return
      }

      const { count, error } = await supabase
        .from('categories')
        .select('id', { count: 'exact', head: true })

      if (error) {
        const message = error.code === '42501' || error.code === 'PGRST301'
          ? 'رفضت صلاحيات قاعدة البيانات طلب الزائر المجهول.'
          : error.code === '42P01'
            ? 'جدول categories غير متاح بالاسم المتوقع.'
            : error.message.toLowerCase().includes('fetch')
              ? 'فشل اتصال الشبكة بخدمة Supabase.'
              : 'فشل استعلام categories. راجع رمز الخطأ أدناه.'
        setResult({ status: 'error', count: null, message: `${message} (رمز: ${error.code || 'غير متاح'})` })
        return
      }

      setResult({ status: 'success', count: count ?? 0, message: 'نجح استعلام الزائر المجهول على جدول categories.' })
    } catch {
      setResult({ status: 'error', count: null, message: 'حدث خطأ اتصال غير متوقع أثناء اختبار الزائر المجهول.' })
    }
  }

  useEffect(() => {
    if (started.current) return
    started.current = true
    void runTest()
  }, [])

  return (
    <main style={{ maxWidth: 760, margin: '48px auto', padding: 24, fontFamily: 'system-ui, sans-serif', color: '#171717', direction: 'rtl' }}>
      <h1>تشخيص اتصال Supabase — Preview</h1>
      <p>هذه صفحة مؤقتة للاختبار فقط. لا تعرض أي قيمة من مفاتيح الاتصال.</p>
      <section style={{ border: '1px solid #ddd', borderRadius: 12, padding: 20, marginTop: 20 }}>
        <h2>متغيرات البيئة داخل import.meta.env</h2>
        <p>VITE_SUPABASE_URL: <strong>{urlAvailable ? 'نعم' : 'لا'}</strong></p>
        <p>VITE_SUPABASE_ANON_KEY: <strong>{anonKeyAvailable ? 'نعم' : 'لا'}</strong></p>
      </section>
      <section style={{ border: '1px solid #ddd', borderRadius: 12, padding: 20, marginTop: 16 }}>
        <h2>اختبار قراءة categories بصلاحيات الزائر المجهول</h2>
        <p aria-live="polite">{result.message}</p>
        {result.status === 'success' && <p><strong>عدد التصنيفات: {result.count}</strong></p>}
        {result.status === 'running' && <p>الاختبار جارٍ...</p>}
        <button type="button" onClick={() => void runTest()} disabled={result.status === 'running'} style={{ padding: '10px 18px', borderRadius: 8, border: '1px solid #999', background: '#fff', cursor: 'pointer' }}>إعادة الاختبار</button>
      </section>
      <p style={{ color: '#666', marginTop: 24, fontSize: 13 }}>لن تُجرى أي كتابة أو تغييرات على قاعدة البيانات.</p>
    </main>
  )
}
