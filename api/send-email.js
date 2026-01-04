
import { Resend } from 'resend';

const resend = new Resend(process.env.RESEND_API_KEY);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { to, businessName, role, inviteLink, inviterName } = req.body;

  if (!to || !businessName || !inviteLink) {
    return res.status(400).json({ error: 'Missing required parameters' });
  }

  try {
    const { data, error } = await resend.emails.send({
      from: 'FinTab OS <onboarding@fintab.io>',
      to: [to],
      subject: `Authorize your access to ${businessName}`,
      html: `
        <div style="font-family: 'Inter', -apple-system, sans-serif; background-color: #f8fafc; padding: 40px 20px; color: #1e293b;">
          <div style="max-width: 500px; margin: 0 auto; background-color: #ffffff; border-radius: 24px; padding: 40px; border: 1px solid #e2e8f0; box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);">
            <div style="margin-bottom: 32px; text-align: center;">
              <h1 style="margin: 0; font-size: 24px; font-weight: 900; text-transform: uppercase; letter-spacing: -0.05em; color: #2563eb;">FinTab</h1>
            </div>
            
            <h2 style="font-size: 20px; font-weight: 800; color: #0f172a; margin-bottom: 16px; text-transform: uppercase; tracking: -0.02em;">Terminal Authorization Required</h2>
            
            <p style="font-size: 14px; line-height: 1.6; color: #64748b; margin-bottom: 24px;">
              You have been enrolled as a <strong>${role}</strong> for the <strong>${businessName}</strong> node by <strong>${inviterName}</strong>.
            </p>
            
            <div style="background-color: #f1f5f9; border-radius: 16px; padding: 20px; margin-bottom: 32px; border-left: 4px solid #2563eb;">
              <p style="margin: 0; font-size: 12px; font-weight: 700; text-transform: uppercase; color: #475569; letter-spacing: 0.1em;">Assigned Node</p>
              <p style="margin: 8px 0 0; font-size: 16px; font-weight: 800; color: #0f172a;">${businessName}</p>
            </div>
            
            <a href="${inviteLink}" style="display: block; width: 100%; padding: 18px 0; background-color: #0f172a; color: #ffffff; text-decoration: none; border-radius: 16px; text-align: center; font-weight: 800; font-size: 12px; text-transform: uppercase; letter-spacing: 0.1em; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);">
              Authorize Entry
            </a>
            
            <p style="font-size: 11px; text-align: center; color: #94a3b8; margin-top: 32px; text-transform: uppercase; font-weight: 600; letter-spacing: 0.05em;">
              Security Node: Verified • Powered by FinTab OS
            </p>
          </div>
        </div>
      `,
    });

    if (error) {
      return res.status(400).json(error);
    }

    res.status(200).json(data);
  } catch (err) {
    res.status(500).json({ error: 'Failed to deliver invitation' });
  }
}
