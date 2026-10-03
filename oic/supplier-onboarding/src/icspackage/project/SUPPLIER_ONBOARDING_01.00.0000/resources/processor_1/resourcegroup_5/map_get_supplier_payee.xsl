<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:template match="/">
      <!-- Query params for GET /paymentsExternalPayees -->
      <q><xsl:value-of select="concat('PayeePartyIdentifier=', $CreateSupplier/erp:Supplier/erp:SupplierPartyId)"/></q>
      <fields>PayeeId,PayeePartyIdentifier,SupplierSiteCode</fields>
      <onlyData>true</onlyData>
   </xsl:template>
</xsl:stylesheet>
