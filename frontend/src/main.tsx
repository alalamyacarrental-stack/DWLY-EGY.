import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import SupabaseDiagnostics from './SupabaseDiagnostics'
import './styles.css'

const showSupabaseDiagnostics = new URLSearchParams(window.location.search).get('supabase-diagnostic') === '1'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>{showSupabaseDiagnostics ? <SupabaseDiagnostics /> : <App />}</React.StrictMode>,
)
