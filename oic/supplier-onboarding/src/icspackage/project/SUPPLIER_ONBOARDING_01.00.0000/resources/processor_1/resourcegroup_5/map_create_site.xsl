<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <!-- Template params: SupplierId = $CreateSupplier/SupplierId, childResource = 'sites' -->
      <erp:SupplierChild>
         <erp:SupplierSite><xsl:value-of select="$req/src:site/src:siteName"/></erp:SupplierSite>
         <erp:ProcurementBU><xsl:value-of select="($req/src:businessUnit[normalize-space()], $DefaultProcurementBU)[1]"/></erp:ProcurementBU>
         <erp:SupplierAddressName><xsl:value-of select="$req/src:address/src:addressName"/></erp:SupplierAddressName>
         <erp:SitePurposePurchasingFlag><xsl:value-of select="($req/src:site/src:purchasingFlag, 'true')[1]"/></erp:SitePurposePurchasingFlag>
         <erp:SitePurposePayFlag><xsl:value-of select="($req/src:site/src:payFlag, 'true')[1]"/></erp:SitePurposePayFlag>
         <xsl:if test="$req/src:site/src:paymentTerms"><erp:PaymentTerms><xsl:value-of select="$req/src:site/src:paymentTerms"/></erp:PaymentTerms></xsl:if>
         <xsl:if test="$req/src:site/src:paymentMethod"><erp:PaymentMethod><xsl:value-of select="$req/src:site/src:paymentMethod"/></erp:PaymentMethod></xsl:if>
      </erp:SupplierChild>
   </xsl:template>
</xsl:stylesheet>
